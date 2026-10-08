//
//  AppDirPlugin.swift
//  mankai
//
//  Created by Travis XU on 1/7/2025.
//

import Foundation

final class AppDirPlugin: ReadWriteFsPlugin {
    static let shared = AppDirPlugin()

    override class func loadPlugins() -> [Plugin] { [shared] }

    private init() {
        let fileManager = FileManager.default
        let mangaDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("mangas")

        if !fileManager.fileExists(atPath: mangaDir.path) {
            do {
                try fileManager.createDirectory(at: mangaDir, withIntermediateDirectories: true)
            } catch {
                Logger.appDirPlugin.error("Failed to create directory \(mangaDir.path): \(error)")
            }
        }

        Logger.appDirPlugin.info(
            "AppDirPlugin initialized with PATH: \(mangaDir.path(percentEncoded: false))")

        super.init(url: mangaDir, id: "mankai")
    }

    override var tags: [String] {
        [String(localized: "builtin"), String(localized: "fs"), String(localized: "editable")]
    }

    override var description: String? { String(localized: "appFsSourceDescription") }

    override var name: String? { String(localized: "appName") }

    override var capabilities: [PluginCapability] { super.capabilities.filter { $0 != .sync } }

    /// Built-in plugin, do nothing
    override func savePlugin() throws {}

    /// Built-in plugin, do nothing
    override func deletePlugin() throws {}
}
