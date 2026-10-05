//
//  Logger.swift
//  mankai
//
//  Created by Travis XU on 21/12/2025.
//

import Foundation
import OSLog

/// Logger categories for different parts of the application
enum LogCategory: String {
    // Services
    case dbService = "DbService"
    case progressService = "ProgressService"
    case mangaSnapshotService = "MangaSnapshotService"
    case libraryService = "LibraryService"
    case updateService = "UpdateService"
    case pluginService = "PluginService"
    case syncService = "SyncService"
    case downloadService = "DownloadService"
    case mmaExporter = "MmaExporter"
    case pdfExporter = "PdfExporter"
    case browseService = "BrowseService"
    case imageProcessingService = "ImageProcessingService"

    // UI
    case ui = "UI"
    case reader = "Reader"
    case smartGrouping = "SmartGrouping"
    case upscaling = "Upscaling"

    // Plugin Types
    case fsPlugin = "FsPlugin"
    case jsPlugin = "JsPlugin"
    case appDirPlugin = "AppDirPlugin"
    case httpPlugin = "HttpPlugin"
    case downloadPlugin = "DownloadPlugin"
    case fsBrowsablePlugin = "FsBrowsablePlugin"
    case appDirBrowsablePlugin = "AppDirBrowsablePlugin"
    case smbBrowsablePlugin = "SmbBrowsablePlugin"
    case sftpBrowsablePlugin = "SftpBrowsablePlugin"
    case nfsBrowsablePlugin = "NfsBrowsablePlugin"
    case webDavBrowsablePlugin = "WebDavBrowsablePlugin"
    case opdsBrowsablePlugin = "OpdsBrowsablePlugin"
    case cbzParser = "CbzParser"
    case cbrParser = "CbrParser"
    case pdfParser = "PdfParser"
    case epubParser = "EpubParser"
    case mmaParser = "MmaParser"

    /// Runtime
    case jsRuntime = "JsRuntime"

    // Sync Engines
    case httpEngine = "HttpEngine"
    case syncEngine = "SyncEngine"

    // General
    case general = "General"
    case authManager = "AuthManager"
    case cacheWrapper = "CacheWrapper"
    case cooldownWrapper = "CooldownWrapper"

    var subsystem: String { return "app.mankai" }

    var category: String { return rawValue }
}

/// Unified logger for the application
final class Logger: Sendable {
    private let osLogger: os.Logger
    private let category: LogCategory

    /// Initialize a logger for a specific category
    /// - Parameter category: The category this logger belongs to
    init(category: LogCategory) {
        self.category = category
        osLogger = os.Logger(subsystem: category.subsystem, category: category.category)
    }

    /// Log a debug message
    /// - Parameters:
    ///   - message: The message to log
    ///   - file: The file where the log is called (automatically populated)
    ///   - function: The function where the log is called (automatically populated)
    ///   - line: The line number where the log is called (automatically populated)
    func debug(
        _ message: String, file _: String = #file, function: String = #function, line: Int = #line
    ) { osLogger.debug("[\(function):\(line)] \(message)") }

    /// Log an info message
    /// - Parameters:
    ///   - message: The message to log
    ///   - file: The file where the log is called (automatically populated)
    ///   - function: The function where the log is called (automatically populated)
    ///   - line: The line number where the log is called (automatically populated)
    func info(
        _ message: String, file _: String = #file, function: String = #function, line: Int = #line
    ) { osLogger.info("[\(function):\(line)] \(message)") }

    /// Log a notice message
    /// - Parameters:
    ///   - message: The message to log
    ///   - file: The file where the log is called (automatically populated)
    ///   - function: The function where the log is called (automatically populated)
    ///   - line: The line number where the log is called (automatically populated)
    func notice(
        _ message: String, file _: String = #file, function: String = #function, line: Int = #line
    ) { osLogger.notice("[\(function):\(line)] \(message)") }

    /// Log a warning message
    /// - Parameters:
    ///   - message: The message to log
    ///   - file: The file where the log is called (automatically populated)
    ///   - function: The function where the log is called (automatically populated)
    ///   - line: The line number where the log is called (automatically populated)
    func warning(
        _ message: String, file _: String = #file, function: String = #function, line: Int = #line
    ) { osLogger.warning("[\(function):\(line)] \(message)") }

    private func formattedError(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
    }

    /// Log an error message
    /// - Parameters:
    ///   - message: The message to log
    ///   - error: Optional error object to include
    ///   - file: The file where the log is called (automatically populated)
    ///   - function: The function where the log is called (automatically populated)
    ///   - line: The line number where the log is called (automatically populated)
    func error(
        _ message: String, error: Error? = nil, file _: String = #file,
        function: String = #function, line: Int = #line
    ) {
        if let error = error {
            osLogger.error(
                "[\(function):\(line)] \(message) - Error: \(self.formattedError(error))")
        } else {
            osLogger.error("[\(function):\(line)] \(message)")
        }
    }

    /// Log a critical/fault message
    /// - Parameters:
    ///   - message: The message to log
    ///   - error: Optional error object to include
    ///   - file: The file where the log is called (automatically populated)
    ///   - function: The function where the log is called (automatically populated)
    ///   - line: The line number where the log is called (automatically populated)
    func critical(
        _ message: String, error: Error? = nil, file _: String = #file,
        function: String = #function, line: Int = #line
    ) {
        if let error = error {
            osLogger.critical(
                "[\(function):\(line)] \(message) - Error: \(self.formattedError(error))")
        } else {
            osLogger.critical("[\(function):\(line)] \(message)")
        }
    }

    /// Log a trace message for detailed debugging
    /// - Parameters:
    ///   - message: The message to log
    ///   - file: The file where the log is called (automatically populated)
    ///   - function: The function where the log is called (automatically populated)
    ///   - line: The line number where the log is called (automatically populated)
    func trace(
        _ message: String, file _: String = #file, function: String = #function, line: Int = #line
    ) { osLogger.trace("[\(function):\(line)] \(message)") }
}

/// Convenience accessors for category-specific loggers
extension Logger {
    // Services
    static let dbService = Logger(category: .dbService)
    static let progressService = Logger(category: .progressService)
    static let mangaSnapshotService = Logger(category: .mangaSnapshotService)
    static let libraryService = Logger(category: .libraryService)
    static let updateService = Logger(category: .updateService)
    static let pluginService = Logger(category: .pluginService)
    static let syncService = Logger(category: .syncService)
    static let downloadService = Logger(category: .downloadService)
    static let mmaExporter = Logger(category: .mmaExporter)
    static let pdfExporter = Logger(category: .pdfExporter)
    static let browseService = Logger(category: .browseService)
    static let imageProcessingService = Logger(category: .imageProcessingService)

    // UI
    static let ui = Logger(category: .ui)
    static let reader = Logger(category: .reader)
    static let smartGrouping = Logger(category: .smartGrouping)
    static let upscaling = Logger(category: .upscaling)

    // Plugin Types
    static let fsPlugin = Logger(category: .fsPlugin)
    static let jsPlugin = Logger(category: .jsPlugin)
    static let httpPlugin = Logger(category: .httpPlugin)
    static let appDirPlugin = Logger(category: .appDirPlugin)
    static let downloadPlugin = Logger(category: .downloadPlugin)
    static let fsBrowsablePlugin = Logger(category: .fsBrowsablePlugin)
    static let appDirBrowsablePlugin = Logger(category: .appDirBrowsablePlugin)
    static let smbBrowsablePlugin = Logger(category: .smbBrowsablePlugin)
    static let sftpBrowsablePlugin = Logger(category: .sftpBrowsablePlugin)
    static let nfsBrowsablePlugin = Logger(category: .nfsBrowsablePlugin)
    static let webDavBrowsablePlugin = Logger(category: .webDavBrowsablePlugin)
    static let opdsBrowsablePlugin = Logger(category: .opdsBrowsablePlugin)
    static let cbzParser = Logger(category: .cbzParser)
    static let cbrParser = Logger(category: .cbrParser)
    static let pdfParser = Logger(category: .pdfParser)
    static let epubParser = Logger(category: .epubParser)
    static let mmaParser = Logger(category: .mmaParser)

    /// Runtime
    static let jsRuntime = Logger(category: .jsRuntime)

    // Sync Engines
    static let httpEngine = Logger(category: .httpEngine)
    static let syncEngine = Logger(category: .syncEngine)

    // General
    static let general = Logger(category: .general)
    static let authManager = Logger(category: .authManager)
    static let cacheWrapper = Logger(category: .cacheWrapper)
    static let cooldownWrapper = Logger(category: .cooldownWrapper)
}
