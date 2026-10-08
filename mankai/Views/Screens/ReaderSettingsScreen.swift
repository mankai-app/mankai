//
//  ReaderSettingsScreen.swift
//  mankai
//
//  Created by Travis XU on 12/7/2025.
//

import SwiftUI

struct ReaderSettingsScreen: View {
    private let showsHeader: Bool

    @AppStorage(SettingsKey.readerType.rawValue) private var readerTypeRawValue: Int =
        SettingsDefaults.readerType.rawValue
    @AppStorage(SettingsKey.imageLayout.rawValue) private var imageLayoutRawValue: Int =
        SettingsDefaults.imageLayout.rawValue
    @AppStorage(SettingsKey.respectMangaReadingDirection.rawValue) private
        var respectMangaReadingDirection: Bool = SettingsDefaults.respectMangaReadingDirection
    @AppStorage(SettingsKey.smartGrouping.rawValue) private var smartGrouping: Bool =
        SettingsDefaults.smartGrouping
    @AppStorage(SettingsKey.smartGroupingSensitivity.rawValue) private var smartGroupingSensitivity:
        Double = SettingsDefaults.smartGroupingSensitivity
    @AppStorage(SettingsKey.showCoverOnExternalDisplay.rawValue) private
        var showCoverOnExternalDisplay: Bool = SettingsDefaults.showCoverOnExternalDisplay

    init(showsHeader: Bool = true) { self.showsHeader = showsHeader }

    var body: some View {
        List {
            if showsHeader {
                SettingsHeaderView(
                    image: Image(systemName: "book.pages.fill"), color: .orange,
                    title: String(localized: "reader"),
                    description: String(localized: "readerDescription"))
            }

            Section("readingMode") {
                Picker(
                    "readerType",
                    selection: Binding(
                        get: {
                            ReaderType(rawValue: readerTypeRawValue) ?? SettingsDefaults.readerType
                        }, set: { readerTypeRawValue = $0.rawValue })
                ) {
                    Text(ReaderType.paged.localizedName).tag(ReaderType.paged)
                    Text(ReaderType.continuous.localizedName).tag(ReaderType.continuous)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("respectMangaReadingDirection", isOn: $respectMangaReadingDirection)
                    Text("respectMangaReadingDirectionDescription").font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if #available(iOS 27.0, *) {
                Section("externalDisplay") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("showCoverOnExternalDisplay", isOn: $showCoverOnExternalDisplay)
                        Text("showCoverOnExternalDisplayDescription").font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("imageGrouping") {
                Picker(
                    "imageLayout",
                    selection: Binding(
                        get: {
                            ImageLayout(rawValue: imageLayoutRawValue)
                                ?? SettingsDefaults.imageLayout
                        }, set: { imageLayoutRawValue = $0.rawValue })
                ) {
                    Text(ImageLayout.auto.localizedName).tag(ImageLayout.auto)
                    Text(ImageLayout.onePerRow.localizedName).tag(ImageLayout.onePerRow)
                    Text(ImageLayout.twoPerRow.localizedName).tag(ImageLayout.twoPerRow)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("smartGrouping", isOn: $smartGrouping)
                    Text("smartGroupingDescription").font(.caption).foregroundColor(.secondary)
                }

                if smartGrouping {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("smartGroupingSensitivity")
                        Slider(value: $smartGroupingSensitivity, in: 0...1, step: 0.1)
                        Text("smartGroupingSensitivityDescription").font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let readerType = ReaderType(rawValue: readerTypeRawValue) {
                switch readerType { case .continuous: ContinuousReaderSettingsView() case .paged:
                    PagedReaderSettingsView()
                }
            }
        }
        .navigationTitle("reader").navigationBarTitleDisplayMode(.inline)
        .onChange(of: smartGrouping) { _, isEnabled in
            guard !isEnabled else { return }

            Task { await SmartGrouping.shared.unloadImmediately() }
        }
    }
}

struct ContinuousReaderSettingsView: View {
    @AppStorage(SettingsKey.CR_readingDirection.rawValue) private var readingDirectionRawValue:
        Int = SettingsDefaults.CR_readingDirection.rawValue
    @AppStorage(SettingsKey.CR_tapNavigation.rawValue) private var tapNavigation: Bool =
        SettingsDefaults.CR_tapNavigation
    @AppStorage(SettingsKey.CR_tapNavigationAcrossChapters.rawValue) private
        var tapNavigationAcrossChapters: Bool = SettingsDefaults.CR_tapNavigationAcrossChapters
    @AppStorage(SettingsKey.CR_snapToPage.rawValue) private var snapToPage: Bool = SettingsDefaults
        .CR_snapToPage
    @AppStorage(SettingsKey.CR_softSnap.rawValue) private var softSnap: Bool = SettingsDefaults
        .CR_softSnap

    var body: some View {
        Section("continuousReaderSettings") {
            Picker(
                "readingDirection",
                selection: Binding(
                    get: {
                        ReadingDirection(rawValue: readingDirectionRawValue)
                            ?? SettingsDefaults.CR_readingDirection
                    }, set: { readingDirectionRawValue = $0.rawValue })
            ) {
                Text(ReadingDirection.leftToRight.localizedName).tag(ReadingDirection.leftToRight)
                Text(ReadingDirection.rightToLeft.localizedName).tag(ReadingDirection.rightToLeft)
            }

            Toggle("tapNavigation", isOn: $tapNavigation)

            if tapNavigation {
                Toggle("tapNavigationAcrossChapters", isOn: $tapNavigationAcrossChapters)
            }

            Toggle("snapToPage", isOn: $snapToPage)

            if snapToPage { Toggle("softSnap", isOn: $softSnap) }
        }
    }
}

struct PagedReaderSettingsView: View {
    @AppStorage(SettingsKey.PR_readingDirection.rawValue) private var readingDirectionRawValue:
        Int = SettingsDefaults.PR_readingDirection.rawValue
    @AppStorage(SettingsKey.PR_navigationOrientation.rawValue) private
        var navigationOrientationRawValue: Int = SettingsDefaults.PR_navigationOrientation.rawValue
    @AppStorage(SettingsKey.PR_pageTransition.rawValue) private var pageTransitionRawValue: Int =
        SettingsDefaults.PR_pageTransition.rawValue
    @AppStorage(SettingsKey.PR_tapNavigation.rawValue) private var tapNavigation: Bool =
        SettingsDefaults.PR_tapNavigation
    @AppStorage(SettingsKey.PR_tapNavigationAcrossChapters.rawValue) private
        var tapNavigationAcrossChapters: Bool = SettingsDefaults.PR_tapNavigationAcrossChapters
    @AppStorage(SettingsKey.PR_tapNavigationBehavior.rawValue) private
        var tapNavigationBehaviorRawValue: Int = SettingsDefaults.PR_tapNavigationBehavior.rawValue

    private var isVertical: Bool {
        NavigationOrientation(rawValue: navigationOrientationRawValue) == .vertical
    }

    var body: some View {
        Section("pagedReaderSettings") {
            Picker(
                "navigationOrientation",
                selection: Binding(
                    get: {
                        NavigationOrientation(rawValue: navigationOrientationRawValue)
                            ?? SettingsDefaults.PR_navigationOrientation
                    }, set: { navigationOrientationRawValue = $0.rawValue })
            ) {
                Text(NavigationOrientation.horizontal.localizedName)
                    .tag(NavigationOrientation.horizontal)
                Text(NavigationOrientation.vertical.localizedName)
                    .tag(NavigationOrientation.vertical)
            }

            Picker(
                "pageTransition",
                selection: Binding(
                    get: {
                        PageTransition(rawValue: pageTransitionRawValue)
                            ?? SettingsDefaults.PR_pageTransition
                    }, set: { pageTransitionRawValue = $0.rawValue })
            ) {
                Text(PageTransition.scroll.localizedName).tag(PageTransition.scroll)
                Text(PageTransition.pageCurl.localizedName).tag(PageTransition.pageCurl)
            }

            Picker(
                "readingDirection",
                selection: Binding(
                    get: {
                        ReadingDirection(rawValue: readingDirectionRawValue)
                            ?? SettingsDefaults.PR_readingDirection
                    }, set: { readingDirectionRawValue = $0.rawValue })
            ) {
                Text(ReadingDirection.leftToRight.localizedName).tag(ReadingDirection.leftToRight)
                Text(ReadingDirection.rightToLeft.localizedName).tag(ReadingDirection.rightToLeft)
            }

            Toggle("tapNavigation", isOn: $tapNavigation)

            if tapNavigation {
                Toggle("tapNavigationAcrossChapters", isOn: $tapNavigationAcrossChapters)
            }

            if tapNavigation && !isVertical {
                Picker(
                    "tapNavigationBehavior",
                    selection: Binding(
                        get: {
                            TapBehavior(rawValue: tapNavigationBehaviorRawValue)
                                ?? SettingsDefaults.PR_tapNavigationBehavior
                        }, set: { tapNavigationBehaviorRawValue = $0.rawValue })
                ) {
                    Text(TapBehavior.previousNext.localizedName).tag(TapBehavior.previousNext)
                    Text(TapBehavior.followReadingDirection.localizedName)
                        .tag(TapBehavior.followReadingDirection)
                }
            }
        }
    }
}
