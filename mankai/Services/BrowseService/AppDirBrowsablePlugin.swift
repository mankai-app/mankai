//
//  AppDirBrowsablePlugin.swift
//  mankai
//
//  Created by Travis XU on 13/7/2026.
//

import Foundation
import GRDB
import SwiftUI

final class AppDirBrowsablePlugin: FsBrowsablePlugin {
    static let shared = try! AppDirBrowsablePlugin()

    override class func loadPlugins() -> [Plugin] { [shared] }

    private init() throws {
        let fileManager = FileManager.default
        let mangaDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("books")

        if !fileManager.fileExists(atPath: mangaDir.path) {
            do {
                try fileManager.createDirectory(at: mangaDir, withIntermediateDirectories: true)
            } catch {
                Logger.appDirBrowsablePlugin.error(
                    "Failed to create directory \(mangaDir.path): \(error)")
            }
        }

        Logger.appDirBrowsablePlugin.info(
            "AppDirBrowsablePlugin initialized with PATH: \(mangaDir.path(percentEncoded: false))")

        try super.init(url: mangaDir, id: "mankai.books", name: nil, shouldSync: false)
    }

    override var name: String? { String(localized: "localDir") }

    override var icon: AnyView { AnyView(Image(systemName: "iphone")) }

    override var color: Color { .accentColor }

    /// Built-in plugin, do nothing
    override func savePlugin(db: Database? = nil) throws {}

    /// Built-in plugin, do nothing
    override func deletePlugin() throws {}
}
