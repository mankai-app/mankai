//
//  MankaiError.swift
//  mankai
//
//  Created by Travis XU on 26/7/2026.
//

import Foundation

enum MankaiErrorDomain: String {
    case readerAdjacency = "app.mankai.reader.adjacency"
    case readerUpscaling = "app.mankai.reader.upscaling"
    case imageProcessing = "app.mankai.image.processing"
    case auth = "app.mankai.auth"
    case browse = "app.mankai.browse"
    case browseArchive = "app.mankai.browse.archive"
    case browseFilesystem = "app.mankai.browse.filesystem"
    case browseSmb = "app.mankai.browse.smb"
    case browseSftp = "app.mankai.browse.sftp"
    case browseNfs = "app.mankai.browse.nfs"
    case browseWebDav = "app.mankai.browse.webdav"
    case browseOpds = "app.mankai.browse.opds"
    case browsePdf = "app.mankai.browse.pdf"
    case browseEpub = "app.mankai.browse.epub"
    case chapter = "app.mankai.chapter"
    case download = "app.mankai.download"
    case export = "app.mankai.export"
    case history = "app.mankai.history"
    case library = "app.mankai.library"
    case plugin = "app.mankai.plugin"
    case pluginDummy = "app.mankai.plugin.dummy"
    case pluginDownload = "app.mankai.plugin.download"
    case pluginFilesystem = "app.mankai.plugin.filesystem"
    case pluginHttp = "app.mankai.plugin.http"
    case pluginJavascript = "app.mankai.plugin.javascript"
    case pluginKomga = "app.mankai.plugin.komga"
    case sync = "app.mankai.sync"
    case syncHttp = "app.mankai.sync.http"
    case syncSupabase = "app.mankai.sync.supabase"
    case update = "app.mankai.update"

    var codePrefix: Int {
        switch self { case .readerAdjacency: return 10 case .readerUpscaling: return 11
            case .imageProcessing: return 12
            case .auth: return 20
            case .browse: return 29
            case .browseArchive: return 30
            case .browseFilesystem: return 31
            case .browseSmb: return 34
            case .browseSftp: return 38
            case .browseNfs: return 37
            case .browseWebDav: return 35
            case .browseOpds: return 36
            case .browsePdf: return 32
            case .browseEpub: return 33
            case .chapter: return 40
            case .download: return 50
            case .export: return 51
            case .history: return 60
            case .library: return 70
            case .plugin: return 80
            case .pluginDummy: return 81
            case .pluginDownload: return 82
            case .pluginFilesystem: return 83
            case .pluginHttp: return 84
            case .pluginJavascript: return 85
            case .pluginKomga: return 86
            case .sync: return 90
            case .syncHttp: return 91
            case .syncSupabase: return 92
            case .update: return 93
        }
    }
}

struct MankaiErrorDefinition {
    let domain: MankaiErrorDomain
    let code: Int
    let messageKey: LocalizedStringResource
}

enum MankaiErrorUserInfoKey {
    static let httpStatusCode = "MankaiHTTPStatusCode"
    static let pluginId = "MankaiPluginID"
}

enum MankaiErrorCode: CaseIterable, Hashable {
    case readerAdjacencyInvalidInputImage
    case readerAdjacencyFailedToCreatePixelBuffer
    case readerUpscalingInvalidInputImage
    case readerUpscalingFailedToCreatePixelBuffer
    case readerUpscalingInvalidTileContext
    case imageProcessingDatabaseNotAvailable
    case imageProcessingFailedToLoad
    case imageProcessingFailedToSave
    case imageProcessingUnknownProcessorType
    case imageProcessingInvalidConfiguration
    case imageProcessingInvalidOrder
    case imageProcessingInvalidInputImage
    case imageProcessingFailed
    case imageProcessingFailedToRender
    case imageProcessingRemoteInvalidURL
    case imageProcessingRemoteInvalidMetadata
    case imageProcessingRemoteInvalidResponse
    case imageProcessingRemoteRequestFailed

    case authMissingCredentialsOrServerUrl
    case authInvalidServerUrl
    case authInvalidCredentials
    case authInvalidJsonResponse
    case authNoRefreshTokenInResponse
    case authMissingRefreshTokenOrServerUrl
    case authInvalidResponse
    case authRefreshFailed
    case authNoAccessTokenInResponse
    case authMissingServerUrl
    case authInvalidUrl
    case authRequestFailed

    case browseInvalidPlugin
    case browseArchiveNoImagesFoundInArchive
    case browseArchiveEntryNotFound
    case browseArchiveInvalidMetadata
    case browseFilesystemFailedToAccessFolder
    case browseFilesystemDatabaseNotAvailable
    case browseFilesystemParserNotFound
    case browseFilesystemInvalidMangaMeta
    case browseFilesystemEntryNotFound
    case browseFilesystemUnableToOpenFileForHashing
    case browseSmbInvalidConnectionConfiguration
    case browseSmbInvalidPlugin
    case browseSftpInvalidConnectionConfiguration
    case browseSftpInvalidPlugin
    case browseNfsInvalidConnectionConfiguration
    case browseNfsInvalidPlugin
    case browseWebDavInvalidConnectionConfiguration
    case browseWebDavInvalidPlugin
    case browseWebDavRequestFailed
    case browseOpdsInvalidPlugin
    case browseOpdsInvalidDocument
    case browsePdfInvalidDocument
    case browsePdfPasswordProtectedDocument
    case browsePdfNoPagesFound
    case browsePdfPageNotFound
    case browsePdfFailedToRenderPage
    case browseEpubInvalidContainer
    case browseEpubInvalidPackage
    case browseEpubProtectedContent
    case browseEpubNoReadableImages
    case browseEpubResourceNotFound

    case chapterMissingChapterId
    case chapterGroupNotFound

    case downloadDatabaseNotAvailable
    case downloadPluginNotFound
    case downloadDisabled
    case exportNoChaptersSelected
    case exportChaptersNotDownloaded
    case exportNoFilesCreated
    case exportInvalidSelection
    case exportFailedToCreatePdf
    case historyFailedToUpdateHistoryRecord
    case libraryFailedToUpdateSavedManga
    case libraryFailedToDeleteSavedManga

    case pluginMangaNotFound
    case pluginDuplicateId
    case pluginDummyCannotBeUsed
    case pluginDownloadDatabaseNotAvailable
    case pluginDownloadMangaNotFound
    case pluginDownloadFailedToLoadMangaDetails
    case pluginDownloadMangaMetaMissing
    case pluginDownloadChapterNotFound
    case pluginDownloadFailedToLoadImage

    case pluginFilesystemFailedToAccessFolder
    case pluginFilesystemPluginIdNotFound
    case pluginFilesystemPluginIdEmpty
    case pluginFilesystemDatabaseNotAvailable
    case pluginFilesystemMangaDirectoryNotFound
    case pluginFilesystemFailedToLoadMangaDetails
    case pluginFilesystemInvalidMangaOrChapterFormat
    case pluginFilesystemFailedToLoadImage
    case pluginFilesystemMissingRequiredFields
    case pluginFilesystemChapterGroupNotFound
    case pluginFilesystemChapterNotFound

    case pluginHttpInvalidUrl
    case pluginHttpInvalidCredentials
    case pluginHttpDatabaseNotAvailable
    case pluginHttpFailedToEncodeMetaData
    case pluginHttpFailedToEncodeConfigValuesData
    case pluginHttpMissingRequiredFields

    case pluginKomgaInvalidUrl
    case pluginKomgaInvalidCredentials
    case pluginKomgaDatabaseNotAvailable
    case pluginKomgaInvalidResponse
    case pluginKomgaRequestFailed

    case pluginJavascriptDatabaseNotAvailable
    case pluginJavascriptFailedToEncodeMetaData
    case pluginJavascriptFailedToEncodeConfigValuesData
    case pluginJavascriptInvalidResultFormatForIsOnline
    case pluginJavascriptInvalidResultFormatForSuggestions
    case pluginJavascriptInvalidResultFormatForMangas
    case pluginJavascriptInvalidResultFormatForDetailedManga
    case pluginJavascriptInvalidMangaOrChapterFormat
    case pluginJavascriptInvalidResultFormatForImages
    case pluginJavascriptInvalidUrl
    case pluginJavascriptInvalidResultFormatForImage
    case pluginJavascriptInvalidBase64StringForImage
    case pluginJavascriptWebViewNotInitialized
    case pluginJavascriptMissingUrlParameter
    case pluginJavascriptInvalidResponseType
    case pluginJavascriptMissingPluginId

    case syncNoEngine
    case syncEngineInactive
    case syncInvalidResponse
    case syncSupabaseInvalidUrl
    case syncSupabaseNotConfigured
    case syncSupabaseNotReady
    case syncSupabaseAuthSettingsFailed
    case syncHttpInvalidResponse
    case updateSyncFailed

    private static let definitions: [MankaiErrorCode: MankaiErrorDefinition] = [
        .readerAdjacencyInvalidInputImage: .init(
            domain: .readerAdjacency, code: 1, messageKey: "invalidInputImage"),
        .readerAdjacencyFailedToCreatePixelBuffer: .init(
            domain: .readerAdjacency, code: 2, messageKey: "failedToCreatePixelBuffer"),
        .readerUpscalingInvalidInputImage: .init(
            domain: .readerUpscaling, code: 1, messageKey: "invalidInputImage"),
        .readerUpscalingFailedToCreatePixelBuffer: .init(
            domain: .readerUpscaling, code: 2, messageKey: "failedToCreatePixelBuffer"),
        .readerUpscalingInvalidTileContext: .init(
            domain: .readerUpscaling, code: 3, messageKey: "invalidTileContext"),
        .imageProcessingDatabaseNotAvailable: .init(
            domain: .imageProcessing, code: 1, messageKey: "databaseNotAvailable"),
        .imageProcessingFailedToLoad: .init(
            domain: .imageProcessing, code: 2, messageKey: "failedToLoadImageProcessors"),
        .imageProcessingFailedToSave: .init(
            domain: .imageProcessing, code: 3, messageKey: "failedToSaveImageProcessor"),
        .imageProcessingUnknownProcessorType: .init(
            domain: .imageProcessing, code: 4, messageKey: "unknownImageProcessorType"),
        .imageProcessingInvalidConfiguration: .init(
            domain: .imageProcessing, code: 5, messageKey: "invalidImageProcessorConfiguration"),
        .imageProcessingInvalidOrder: .init(
            domain: .imageProcessing, code: 6, messageKey: "invalidImageProcessorOrder"),
        .imageProcessingInvalidInputImage: .init(
            domain: .imageProcessing, code: 7, messageKey: "invalidInputImage"),
        .imageProcessingFailed: .init(
            domain: .imageProcessing, code: 8, messageKey: "imageProcessingFailed"),
        .imageProcessingFailedToRender: .init(
            domain: .imageProcessing, code: 9, messageKey: "failedToRenderImage"),
        .imageProcessingRemoteInvalidURL: .init(
            domain: .imageProcessing, code: 10, messageKey: "invalidUrl"),
        .imageProcessingRemoteInvalidMetadata: .init(
            domain: .imageProcessing, code: 11, messageKey: "invalidImageProcessorConfiguration"),
        .imageProcessingRemoteInvalidResponse: .init(
            domain: .imageProcessing, code: 12, messageKey: "invalidResponse"),
        .imageProcessingRemoteRequestFailed: .init(
            domain: .imageProcessing, code: 13, messageKey: "httpRequestFailed"),

        .authMissingCredentialsOrServerUrl: .init(
            domain: .auth, code: 1, messageKey: "missingCredentialsOrServerUrl"),
        .authInvalidServerUrl: .init(domain: .auth, code: 2, messageKey: "invalidServerUrl"),
        .authInvalidCredentials: .init(domain: .auth, code: 3, messageKey: "invalidCredentials"),
        .authInvalidJsonResponse: .init(domain: .auth, code: 4, messageKey: "invalidJsonResponse"),
        .authNoRefreshTokenInResponse: .init(
            domain: .auth, code: 5, messageKey: "noRefreshTokenInResponse"),
        .authMissingRefreshTokenOrServerUrl: .init(
            domain: .auth, code: 6, messageKey: "missingRefreshTokenOrServerUrl"),
        .authInvalidResponse: .init(domain: .auth, code: 7, messageKey: "invalidResponse"),
        .authRefreshFailed: .init(domain: .auth, code: 8, messageKey: "refreshFailed"),
        .authNoAccessTokenInResponse: .init(
            domain: .auth, code: 9, messageKey: "noAccessTokenInResponse"),
        .authMissingServerUrl: .init(domain: .auth, code: 10, messageKey: "missingServerUrl"),
        .authInvalidUrl: .init(domain: .auth, code: 11, messageKey: "invalidUrl"),
        .authRequestFailed: .init(domain: .auth, code: 12, messageKey: "httpRequestFailed"),

        .browseInvalidPlugin: .init(domain: .browse, code: 1, messageKey: "invalidShare"),
        .browseArchiveNoImagesFoundInArchive: .init(
            domain: .browseArchive, code: 1, messageKey: "noImagesFoundInArchive"),
        .browseArchiveEntryNotFound: .init(
            domain: .browseArchive, code: 2, messageKey: "entryNotFound"),
        .browseArchiveInvalidMetadata: .init(
            domain: .browseArchive, code: 3, messageKey: "invalidMangaMeta"),
        .browseFilesystemFailedToAccessFolder: .init(
            domain: .browseFilesystem, code: 1, messageKey: "failedToAccessFolder"),
        .browseFilesystemDatabaseNotAvailable: .init(
            domain: .browseFilesystem, code: 2, messageKey: "databaseNotAvailable"),
        .browseFilesystemParserNotFound: .init(
            domain: .browseFilesystem, code: 3, messageKey: "parserNotFound"),
        .browseFilesystemInvalidMangaMeta: .init(
            domain: .browseFilesystem, code: 4, messageKey: "invalidMangaMeta"),
        .browseFilesystemEntryNotFound: .init(
            domain: .browseFilesystem, code: 5, messageKey: "entryNotFound"),
        .browseFilesystemUnableToOpenFileForHashing: .init(
            domain: .browseFilesystem, code: 6, messageKey: "unableToOpenFileForHashing"),
        .browseSmbInvalidConnectionConfiguration: .init(
            domain: .browseSmb, code: 1, messageKey: "invalidSmbConnectionConfiguration"),
        .browseSmbInvalidPlugin: .init(domain: .browseSmb, code: 2, messageKey: "invalidSmbShare"),
        .browseSftpInvalidConnectionConfiguration: .init(
            domain: .browseSftp, code: 1, messageKey: "invalidSftpConnectionConfiguration"),
        .browseSftpInvalidPlugin: .init(
            domain: .browseSftp, code: 2, messageKey: "invalidSftpShare"),
        .browseNfsInvalidConnectionConfiguration: .init(
            domain: .browseNfs, code: 1, messageKey: "invalidNfsConnectionConfiguration"),
        .browseNfsInvalidPlugin: .init(domain: .browseNfs, code: 2, messageKey: "invalidNfsShare"),
        .browseWebDavInvalidConnectionConfiguration: .init(
            domain: .browseWebDav, code: 1, messageKey: "invalidWebDavConnectionConfiguration"),
        .browseWebDavInvalidPlugin: .init(
            domain: .browseWebDav, code: 2, messageKey: "invalidWebDavShare"),
        .browseWebDavRequestFailed: .init(
            domain: .browseWebDav, code: 3, messageKey: "webDavRequestFailed"),
        .browseOpdsInvalidPlugin: .init(
            domain: .browseOpds, code: 1, messageKey: "invalidOpdsShare"),
        .browseOpdsInvalidDocument: .init(
            domain: .browseOpds, code: 2, messageKey: "invalidOpdsDocument"),
        .browsePdfInvalidDocument: .init(
            domain: .browsePdf, code: 1, messageKey: "invalidPdfDocument"),
        .browsePdfPasswordProtectedDocument: .init(
            domain: .browsePdf, code: 2, messageKey: "passwordProtectedPdfNotSupported"),
        .browsePdfNoPagesFound: .init(domain: .browsePdf, code: 3, messageKey: "noPagesFoundInPdf"),
        .browsePdfPageNotFound: .init(domain: .browsePdf, code: 4, messageKey: "pdfPageNotFound"),
        .browsePdfFailedToRenderPage: .init(
            domain: .browsePdf, code: 5, messageKey: "failedToRenderPdfPage"),
        .browseEpubInvalidContainer: .init(
            domain: .browseEpub, code: 1, messageKey: "invalidEpubContainer"),
        .browseEpubInvalidPackage: .init(
            domain: .browseEpub, code: 2, messageKey: "invalidEpubPackage"),
        .browseEpubProtectedContent: .init(
            domain: .browseEpub, code: 3, messageKey: "protectedEpubContentNotSupported"),
        .browseEpubNoReadableImages: .init(
            domain: .browseEpub, code: 4, messageKey: "noReadableImagesInEpub"),
        .browseEpubResourceNotFound: .init(
            domain: .browseEpub, code: 5, messageKey: "epubResourceNotFound"),

        .chapterMissingChapterId: .init(domain: .chapter, code: 1, messageKey: "missingChapterId"),
        .chapterGroupNotFound: .init(domain: .chapter, code: 2, messageKey: "chapterGroupNotFound"),

        .downloadDatabaseNotAvailable: .init(
            domain: .download, code: 1, messageKey: "downloadDatabaseNotAvailable"),
        .downloadPluginNotFound: .init(domain: .download, code: 2, messageKey: "pluginNotFound"),
        .downloadDisabled: .init(domain: .download, code: 3, messageKey: "downloadDisabled"),
        .exportNoChaptersSelected: .init(
            domain: .export, code: 1, messageKey: "exportNoChaptersSelected"),
        .exportChaptersNotDownloaded: .init(
            domain: .export, code: 2, messageKey: "exportChaptersNotDownloaded"),
        .exportNoFilesCreated: .init(domain: .export, code: 3, messageKey: "exportNoFilesCreated"),
        .exportInvalidSelection: .init(
            domain: .export, code: 4, messageKey: "exportInvalidSelection"),
        .exportFailedToCreatePdf: .init(
            domain: .export, code: 5, messageKey: "exportFailedToCreatePdf"),
        .historyFailedToUpdateHistoryRecord: .init(
            domain: .history, code: 1, messageKey: "failedToUpdateHistoryRecord"),
        .libraryFailedToUpdateSavedManga: .init(
            domain: .library, code: 1, messageKey: "failedToUpdateSavedManga"),
        .libraryFailedToDeleteSavedManga: .init(
            domain: .library, code: 2, messageKey: "failedToDeleteSavedManga"),

        .pluginMangaNotFound: .init(domain: .plugin, code: 1, messageKey: "mangaNotFound"),
        .pluginDuplicateId: .init(
            domain: .plugin, code: 2, messageKey: "duplicatePluginIdMessageFormat"),
        .pluginDummyCannotBeUsed: .init(
            domain: .pluginDummy, code: 1, messageKey: "dummyPluginCannotBeUsed"),
        .pluginDownloadDatabaseNotAvailable: .init(
            domain: .pluginDownload, code: 1, messageKey: "databaseNotAvailable"),
        .pluginDownloadMangaNotFound: .init(
            domain: .pluginDownload, code: 2, messageKey: "mangaNotFound"),
        .pluginDownloadFailedToLoadMangaDetails: .init(
            domain: .pluginDownload, code: 3, messageKey: "failedToLoadMangaDetails"),
        .pluginDownloadMangaMetaMissing: .init(
            domain: .pluginDownload, code: 4, messageKey: "mangaMetaMissing"),
        .pluginDownloadChapterNotFound: .init(
            domain: .pluginDownload, code: 5, messageKey: "chapterNotFound"),
        .pluginDownloadFailedToLoadImage: .init(
            domain: .pluginDownload, code: 6, messageKey: "failedToLoadImage"),

        .pluginFilesystemFailedToAccessFolder: .init(
            domain: .pluginFilesystem, code: 1, messageKey: "failedToAccessFolder"),
        .pluginFilesystemPluginIdNotFound: .init(
            domain: .pluginFilesystem, code: 2, messageKey: "pluginIdNotFound"),
        .pluginFilesystemPluginIdEmpty: .init(
            domain: .pluginFilesystem, code: 3, messageKey: "pluginIdEmpty"),
        .pluginFilesystemDatabaseNotAvailable: .init(
            domain: .pluginFilesystem, code: 4, messageKey: "databaseNotAvailable"),
        .pluginFilesystemMangaDirectoryNotFound: .init(
            domain: .pluginFilesystem, code: 5, messageKey: "mangaDirectoryNotFound"),
        .pluginFilesystemFailedToLoadMangaDetails: .init(
            domain: .pluginFilesystem, code: 6, messageKey: "failedToLoadMangaDetails"),
        .pluginFilesystemInvalidMangaOrChapterFormat: .init(
            domain: .pluginFilesystem, code: 7, messageKey: "invalidMangaOrChapterFormat"),
        .pluginFilesystemFailedToLoadImage: .init(
            domain: .pluginFilesystem, code: 8, messageKey: "failedToLoadImage"),
        .pluginFilesystemMissingRequiredFields: .init(
            domain: .pluginFilesystem, code: 9, messageKey: "missingRequiredFields"),
        .pluginFilesystemChapterGroupNotFound: .init(
            domain: .pluginFilesystem, code: 10, messageKey: "chapterGroupNotFound"),
        .pluginFilesystemChapterNotFound: .init(
            domain: .pluginFilesystem, code: 11, messageKey: "chapterNotFound"),

        .pluginHttpInvalidUrl: .init(domain: .pluginHttp, code: 1, messageKey: "invalidUrl"),
        .pluginHttpInvalidCredentials: .init(
            domain: .pluginHttp, code: 2, messageKey: "invalidCredentials"),
        .pluginHttpDatabaseNotAvailable: .init(
            domain: .pluginHttp, code: 3, messageKey: "databaseNotAvailable"),
        .pluginHttpFailedToEncodeMetaData: .init(
            domain: .pluginHttp, code: 4, messageKey: "failedToEncodeMetaData"),
        .pluginHttpFailedToEncodeConfigValuesData: .init(
            domain: .pluginHttp, code: 5, messageKey: "failedToEncodeConfigValuesData"),
        .pluginHttpMissingRequiredFields: .init(
            domain: .pluginHttp, code: 6, messageKey: "missingRequiredFields"),

        .pluginKomgaInvalidUrl: .init(domain: .pluginKomga, code: 1, messageKey: "invalidUrl"),
        .pluginKomgaInvalidCredentials: .init(
            domain: .pluginKomga, code: 2, messageKey: "invalidCredentials"),
        .pluginKomgaDatabaseNotAvailable: .init(
            domain: .pluginKomga, code: 3, messageKey: "databaseNotAvailable"),
        .pluginKomgaInvalidResponse: .init(
            domain: .pluginKomga, code: 4, messageKey: "invalidResponse"),
        .pluginKomgaRequestFailed: .init(
            domain: .pluginKomga, code: 5, messageKey: "httpRequestFailed"),

        .pluginJavascriptDatabaseNotAvailable: .init(
            domain: .pluginJavascript, code: 1, messageKey: "databaseNotAvailable"),
        .pluginJavascriptFailedToEncodeMetaData: .init(
            domain: .pluginJavascript, code: 2, messageKey: "failedToEncodeMetaData"),
        .pluginJavascriptFailedToEncodeConfigValuesData: .init(
            domain: .pluginJavascript, code: 3, messageKey: "failedToEncodeConfigValuesData"),
        .pluginJavascriptInvalidResultFormatForIsOnline: .init(
            domain: .pluginJavascript, code: 4, messageKey: "invalidResultFormatForIsOnline"),
        .pluginJavascriptInvalidResultFormatForSuggestions: .init(
            domain: .pluginJavascript, code: 5, messageKey: "invalidResultFormatForSuggestions"),
        .pluginJavascriptInvalidResultFormatForMangas: .init(
            domain: .pluginJavascript, code: 6, messageKey: "invalidResultFormatForMangas"),
        .pluginJavascriptInvalidResultFormatForDetailedManga: .init(
            domain: .pluginJavascript, code: 7, messageKey: "invalidResultFormatForDetailedManga"),
        .pluginJavascriptInvalidMangaOrChapterFormat: .init(
            domain: .pluginJavascript, code: 8, messageKey: "invalidMangaOrChapterFormat"),
        .pluginJavascriptInvalidResultFormatForImages: .init(
            domain: .pluginJavascript, code: 9, messageKey: "invalidResultFormatForImages"),
        .pluginJavascriptInvalidUrl: .init(
            domain: .pluginJavascript, code: 10, messageKey: "invalidUrl"),
        .pluginJavascriptInvalidResultFormatForImage: .init(
            domain: .pluginJavascript, code: 11, messageKey: "invalidResultFormatForImage"),
        .pluginJavascriptInvalidBase64StringForImage: .init(
            domain: .pluginJavascript, code: 12, messageKey: "invalidBase64StringForImage"),
        .pluginJavascriptWebViewNotInitialized: .init(
            domain: .pluginJavascript, code: 13, messageKey: "webViewNotInitialized"),
        .pluginJavascriptMissingUrlParameter: .init(
            domain: .pluginJavascript, code: 14, messageKey: "missingUrlParameter"),
        .pluginJavascriptInvalidResponseType: .init(
            domain: .pluginJavascript, code: 15, messageKey: "invalidResponseType"),
        .pluginJavascriptMissingPluginId: .init(
            domain: .pluginJavascript, code: 16, messageKey: "missingPluginId"),

        .syncNoEngine: .init(domain: .sync, code: 1, messageKey: "noSyncEngine"),
        .syncEngineInactive: .init(domain: .sync, code: 2, messageKey: "syncEngineInactive"),
        .syncInvalidResponse: .init(domain: .sync, code: 3, messageKey: "invalidResponseType"),
        .syncSupabaseInvalidUrl: .init(domain: .syncSupabase, code: 1, messageKey: "invalidUrl"),
        .syncSupabaseNotConfigured: .init(
            domain: .syncSupabase, code: 2, messageKey: "supabaseNotConfigured"),
        .syncSupabaseNotReady: .init(
            domain: .syncSupabase, code: 3, messageKey: "supabaseNotReady"),
        .syncSupabaseAuthSettingsFailed: .init(
            domain: .syncSupabase, code: 4, messageKey: "failedToLoadSignInMethods"),
        .syncHttpInvalidResponse: .init(
            domain: .syncHttp, code: 1, messageKey: "invalidResponseType"),
        .updateSyncFailed: .init(domain: .update, code: 1, messageKey: "syncFailed")
    ]

    var definition: MankaiErrorDefinition { Self.definitions[self]! }

    var errorCode: Int { definition.domain.codePrefix * 100 + definition.code }

    func matches(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == definition.domain.rawValue && error.code == errorCode
    }

    func makeError(
        messageOverride: String? = nil, messageArguments: [CVarArg] = [],
        underlyingError: Error? = nil, additionalUserInfo: [String: Any] = [:]
    ) -> NSError {
        var userInfo = additionalUserInfo
        let message = messageOverride ?? String(localized: definition.messageKey)
        userInfo[NSLocalizedDescriptionKey] =
            messageArguments.isEmpty
            ? message : String(format: message, locale: .current, arguments: messageArguments)

        if let underlyingError { userInfo[NSUnderlyingErrorKey] = underlyingError }

        return NSError(domain: definition.domain.rawValue, code: errorCode, userInfo: userInfo)
    }
}
