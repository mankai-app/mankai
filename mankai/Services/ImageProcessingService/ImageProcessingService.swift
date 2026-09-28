//
//  ImageProcessingService.swift
//  mankai
//
//  Created by Travis XU on 26/9/2026.
//

import Combine
import CoreImage
import GRDB
import UIKit

struct ImageProcessorInstance: Identifiable {
    var id: String
    var order: Int
    var isEnabled: Bool
    var processor: any ImageProcessor

    var type: String { Swift.type(of: processor).type }
    var title: String { processor.title }
    var description: String { processor.description }

    @MainActor init(model: ImageProcessorModel) throws {
        id = model.id
        order = model.order
        isEnabled = model.isEnabled
        switch model.type { case UpscalingImageProcessor.type:
            processor = try UpscalingImageProcessor.decode(model)
            case DownsampleImageProcessor.type:
                processor = try DownsampleImageProcessor.decode(model)
            case RemoteImageProcessor.type: processor = try RemoteImageProcessor.decode(model)
            default: throw MankaiErrorCode.imageProcessingUnknownProcessorType.makeError()
        }
    }

    @MainActor func encode() throws -> ImageProcessorModel {
        try processor.encode(id: id, order: order, isEnabled: isEnabled)
    }
}

/// Owns the ordered reader image pipeline and its persisted processor settings.
@MainActor final class ImageProcessingService: ObservableObject {
    static let shared = ImageProcessingService()

    @Published private(set) var processors: [ImageProcessorInstance] = []
    @Published var errorMessage: String?
    nonisolated private static let renderingContext = CIContext(options: [
        .cacheIntermediates: false
    ])

    private init() {
        guard let dbPool = DbService.shared.appDb else {
            report(.imageProcessingDatabaseNotAvailable, context: "Loading image processors")
            return
        }
        do {
            let models = try dbPool.read { db in try ImageProcessorModel.fetchAll(db) }
            processors = models.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
                .compactMap { model in
                    do { return try ImageProcessorInstance(model: model) } catch {
                        Logger.imageProcessingService.error(
                            "Failed to decode image processor \(model.type)", error: error)
                        errorMessage = error.localizedDescription
                        return nil
                    }
                }
            Logger.imageProcessingService.info("Loaded \(processors.count) image processors")
        } catch {
            report(
                .imageProcessingFailedToLoad, context: "Loading image processors", underlying: error
            )
        }
    }

    @discardableResult func add(_ processor: any ImageProcessor) -> Bool {
        let type = Swift.type(of: processor).type
        guard let dbPool = DbService.shared.appDb else {
            report(.imageProcessingDatabaseNotAvailable, context: "Adding image processor \(type)")
            return false
        }
        do {
            let order = (processors.map(\.order).max() ?? -1) + 1
            let model = try processor.encode(id: UUID().uuidString, order: order, isEnabled: true)
            let instance = try ImageProcessorInstance(model: model)
            try dbPool.write { db in try model.insert(db) }
            processors.append(instance)
            Logger.imageProcessingService.info("Added image processor \(type)")
            return true
        } catch {
            report(
                .imageProcessingFailedToSave, context: "Adding image processor \(type)",
                underlying: error)
            return false
        }
    }

    func processor<P: ImageProcessor>(id: String, as type: P.Type) -> P? {
        processors.first(where: { $0.id == id })?.processor as? P
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard var instance = processors.first(where: { $0.id == id }) else { return }
        instance.isEnabled = enabled
        save(instance)
    }

    func update<P: ImageProcessor>(id: String, processor: P) {
        guard var current = processors.first(where: { $0.id == id && $0.type == P.type }) else {
            return
        }
        current.processor = processor
        save(current)
    }

    func remove(ids: [String]) {
        guard let dbPool = DbService.shared.appDb else {
            report(.imageProcessingDatabaseNotAvailable, context: "Removing image processors")
            return
        }
        do {
            try dbPool.write { db in
                for id in ids { _ = try ImageProcessorModel.deleteOne(db, key: id) }
            }
            processors.removeAll { ids.contains($0.id) }
            Logger.imageProcessingService.info("Removed \(ids.count) image processors")
        } catch {
            report(
                .imageProcessingFailedToSave, context: "Removing image processors",
                underlying: error)
        }
    }

    /// Persists the complete execution order. Callers must supply each known ID once.
    func setOrder(_ ids: [String]) {
        guard ids.count == processors.count, Set(ids) == Set(processors.map(\.id)) else {
            report(.imageProcessingInvalidOrder, context: "Changing image processor order")
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: processors.map { ($0.id, $0) })
        let reordered = ids.enumerated()
            .compactMap { index, id -> ImageProcessorInstance? in
                guard var instance = byID[id] else { return nil }
                instance.order = index
                return instance
            }
        do {
            guard let dbPool = DbService.shared.appDb else {
                report(
                    .imageProcessingDatabaseNotAvailable, context: "Changing image processor order")
                return
            }
            let models = try reordered.map { try $0.encode() }
            try dbPool.write { db in for model in models { try model.update(db) } }
            processors = reordered
            Logger.imageProcessingService.info("Changed image processor order")
        } catch {
            report(
                .imageProcessingFailedToSave, context: "Changing image processor order",
                underlying: error)
        }
    }

    /// A fast-only pipeline completes before the image is handed to the UI.
    /// Any slow processor allows a temporary source image and publishes the final result later.
    func load(data: Data) async -> (image: UIImage, processingTask: Task<UIImage?, Never>?)? {
        let pipeline = processors.filter(\.isEnabled).map(\.processor)

        guard !pipeline.isEmpty else {
            guard
                let image =
                    await Task.detached(
                        priority: .userInitiated, operation: { UIImage(data: data) }
                    )
                    .value
            else {
                Logger.imageProcessingService.error(
                    "Failed to decode source image",
                    error: MankaiErrorCode.imageProcessingInvalidInputImage.makeError())
                return nil
            }
            return (image, nil)
        }

        let pointSize = UIApplication.windowBounds.size
        let task = Task.detached(priority: .utility) {
            await Self.process(data: data, with: pipeline, pointSize: pointSize)
        }

        if pipeline.allSatisfy(\.isFast) {
            if let final = await task.value { return (final, nil) }
            guard let source = UIImage(data: data) else {
                Logger.imageProcessingService.error(
                    "Failed to decode source image after processing failed",
                    error: MankaiErrorCode.imageProcessingInvalidInputImage.makeError())
                return nil
            }
            return (source, nil)
        }

        guard
            let source =
                await Task.detached(priority: .userInitiated, operation: { UIImage(data: data) })
                .value
        else {
            task.cancel()
            Logger.imageProcessingService.error(
                "Failed to decode temporary source image",
                error: MankaiErrorCode.imageProcessingInvalidInputImage.makeError())
            return nil
        }
        return (source, task)
    }

    nonisolated private static func process(
        data: Data, with pipeline: [any ImageProcessor], pointSize: CGSize
    ) async -> UIImage? {
        Logger.imageProcessingService.debug("Running \(pipeline.count) image processors")
        guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            Logger.imageProcessingService.error(
                "Failed to decode source image",
                error: MankaiErrorCode.imageProcessingInvalidInputImage.makeError())
            return nil
        }
        do {
            for processor in pipeline {
                try Task.checkCancellation()
                image = try await processor.process(image: image, pointSize: pointSize)
            }
            try Task.checkCancellation()
        } catch is CancellationError { return nil } catch {
            Logger.imageProcessingService.error(
                "Failed to process reader image",
                error: MankaiErrorCode.imageProcessingFailed.makeError(underlyingError: error))
            return nil
        }

        guard let rendered = renderingContext.createCGImage(image, from: image.extent.integral)
        else {
            Logger.imageProcessingService.error(
                "Failed to render processed reader image",
                error: MankaiErrorCode.imageProcessingFailedToRender.makeError())
            return nil
        }
        return UIImage(cgImage: rendered)
    }

    private func save(_ instance: ImageProcessorInstance) {
        do {
            guard let dbPool = DbService.shared.appDb else {
                report(
                    .imageProcessingDatabaseNotAvailable,
                    context: "Saving image processor \(instance.type)")
                return
            }
            let model = try instance.encode()
            try dbPool.write { db in try model.update(db) }
            if let index = processors.firstIndex(where: { $0.id == instance.id }) {
                processors[index] = instance
            }
            Logger.imageProcessingService.debug("Saved image processor \(instance.type)")
        } catch {
            report(
                .imageProcessingFailedToSave, context: "Saving image processor \(instance.type)",
                underlying: error)
        }
    }

    private func report(_ code: MankaiErrorCode, context: String, underlying: Error? = nil) {
        let error = code.makeError(underlyingError: underlying)
        Logger.imageProcessingService.error(context, error: error)
        errorMessage = error.localizedDescription
    }

}
