//
//  AppearanceSettingsScreen.swift
//  mankai
//
//  Created by Travis XU on 31/8/2026.
//

import SwiftUI

struct AppearanceSettingsScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.accentColor.rawValue) private var accentColorRawValue: String =
        SettingsDefaults.accentColor.rawValue
    @State private var selectedIcon: AppIconOption = .sakura
    @State private var pendingIcon: AppIconOption?
    @State private var errorMessage: String?
    @State private var showsAccentColorRestartNotice = false

    var body: some View {
        List {
            if UIApplication.shared.supportsAlternateIcons {
                Section {
                    ForEach(AppIconOption.allCases) { icon in
                        Button {
                            select(icon)
                        } label: {
                            HStack(spacing: 16) {
                                Image(icon.previewAssetName).resizable()
                                    .aspectRatio(contentMode: .fit).frame(width: 72, height: 72)
                                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(icon.localizedName).foregroundStyle(.primary)

                                    if icon == .sakura {
                                        Text("default").font(.caption).foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if pendingIcon == icon {
                                    ProgressView()
                                } else if selectedIcon == icon {
                                    Image(systemName: "checkmark.circle.fill").font(.title2)
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("appIcon")
                } footer: {
                    Text("appIconDescription")
                }
            }

            Section {
                ForEach(AppAccentColor.allCases) { accentColor in
                    Button {
                        guard selectedAccentColor != accentColor else { return }
                        accentColorRawValue = accentColor.rawValue
                        showsAccentColorRestartNotice =
                            ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 17
                    } label: {
                        HStack(spacing: 16) {
                            Circle().fill(accentColor.color).frame(width: 36, height: 36)
                                .overlay {
                                    Circle().stroke(Color(uiColor: .separator), lineWidth: 0.5)
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(accentColor.localizedName).foregroundStyle(.primary)

                                if accentColor == .sakura {
                                    Text("default").font(.caption).foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if selectedAccentColor == accentColor {
                                Image(systemName: "checkmark.circle.fill").font(.title2)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("accentColor")
            } footer: {
                Text("accentColorDescription")
            }
        }
        .navigationTitle("appearance").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshSelection)
        .onChange(of: scenePhase) { _, newPhase in if newPhase == .active { refreshSelection() } }
        .alert(
            "appIconUpdateFailed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } })
        ) {
            Button("ok", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("accentColorRestartNoticeTitle", isPresented: $showsAccentColorRestartNotice) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("accentColorRestartNoticeMessage")
        }
    }

    private var selectedAccentColor: AppAccentColor {
        AppAccentColor(rawValue: accentColorRawValue) ?? SettingsDefaults.accentColor
    }

    private func select(_ icon: AppIconOption) {
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = String(localized: "appIconUnavailable")
            return
        }

        guard selectedIcon != icon else { return }

        pendingIcon = icon
        UIApplication.shared.setAlternateIconName(icon.alternateIconName) { error in
            Task { @MainActor in
                pendingIcon = nil

                if let error {
                    Logger.ui.error("Failed to update app icon", error: error)
                    errorMessage = error.localizedDescription
                }

                refreshSelection()
            }
        }
    }

    private func refreshSelection() {
        selectedIcon = AppIconOption(alternateIconName: UIApplication.shared.alternateIconName)
    }
}

private enum AppIconOption: String, CaseIterable, Identifiable {
    case sakura
    case lily
    case rose
    case sunflower
    case lotus
    case hydrangea

    var id: Self { self }

    init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .sakura
    }

    var alternateIconName: String? {
        switch self { case .sakura: nil case .lily: "LilyIcon" case .rose: "RoseIcon"
            case .sunflower: "SunflowerIcon"
            case .lotus: "LotusIcon"
            case .hydrangea: "HydrangeaIcon"
        }
    }

    var previewAssetName: String { "\(alternateIconName ?? "SakuraIcon")Preview" }

    var localizedName: String {
        switch self { case .sakura: String(localized: "sakura") case .lily:
            String(localized: "lily")
            case .rose: String(localized: "rose")
            case .sunflower: String(localized: "sunflower")
            case .lotus: String(localized: "lotus")
            case .hydrangea: String(localized: "hydrangea")
        }
    }
}
