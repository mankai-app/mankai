//
//  SettingsKey.swift
//  mankai
//
//  Created by Travis XU on 27/6/2025.
//

import Foundation

enum SettingsKey: String {
    case isDuo
    case hideBuiltInPlugins
    case showDebugScreen
    case checkClipboard
    case filesViewMode
    case accentColor

    /// Cache Settings
    case inMemoryCacheItemCount
    case diskCacheSizeLimit

    // Shared Reader Settings
    case readerType
    case imageLayout
    case respectMangaReadingDirection
    case smartGrouping
    case smartGroupingSensitivity
    case showCoverOnExternalDisplay

    // Continuous Reader
    case CR_readingDirection
    case CR_tapNavigation
    case CR_tapNavigationAcrossChapters
    case CR_snapToPage
    case CR_softSnap

    // Paged Reader
    case PR_navigationOrientation
    case PR_pageTransition
    case PR_readingDirection
    case PR_tapNavigation
    case PR_tapNavigationAcrossChapters
    case PR_tapNavigationBehavior
}

enum FilesViewMode: String {
    case grid
    case list
}

enum ReaderType: Int {
    case continuous = 1
    case paged = 2

    var localizedName: String {
        switch self { case .continuous: return String(localized: "continuous") case .paged:
            return String(localized: "paged")
        }
    }
}

enum ImageLayout: Int {
    case auto = 1
    case onePerRow = 2
    case twoPerRow = 3

    var localizedName: String {
        switch self { case .auto: return String(localized: "auto") case .onePerRow:
            return String(localized: "onePerRow")
            case .twoPerRow: return String(localized: "twoPerRow")
        }
    }
}

enum ReadingDirection: Int, Codable {
    case leftToRight = 1
    case rightToLeft = 2
    case vertical = 3

    var localizedName: String {
        switch self { case .leftToRight: return String(localized: "leftToRight") case .rightToLeft:
            return String(localized: "rightToLeft")
            case .vertical: return String(localized: "vertical")
        }
    }
}

enum TapBehavior: Int {
    case previousNext = 1  // Left = previous, Right = next
    case followReadingDirection = 2  // Follow reading direction

    var localizedName: String {
        switch self { case .previousNext: return String(localized: "previousNext")
            case .followReadingDirection: return String(localized: "followReadingDirection")
        }
    }
}

enum NavigationOrientation: Int {
    case horizontal = 1
    case vertical = 2

    var localizedName: String {
        switch self { case .horizontal: return String(localized: "horizontal") case .vertical:
            return String(localized: "vertical")
        }
    }
}

enum PageTransition: Int {
    case scroll = 1
    case pageCurl = 2

    var localizedName: String {
        switch self { case .scroll: return String(localized: "scroll") case .pageCurl:
            return String(localized: "pageCurl")
        }
    }
}

enum DiskCacheLimit: Int {
    case fiveHundredMB = 500
    case oneGB = 1024
    case twoGB = 2048
    case fiveGB = 5120
    case tenGB = 10240

    var localizedName: String {
        switch self { case .fiveHundredMB: return String(localized: "500mb") case .oneGB:
            return String(localized: "1gb")
            case .twoGB: return String(localized: "2gb")
            case .fiveGB: return String(localized: "5gb")
            case .tenGB: return String(localized: "10gb")
        }
    }
}
