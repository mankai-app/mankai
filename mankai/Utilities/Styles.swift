//
//  Styles.swift
//  mankai
//
//  Created by Travis XU on 25/6/2025.
//

import SwiftUI

struct AdaptiveGlassBackgroundModifier<BackgroundShape: Shape>: ViewModifier {
    let shape: BackgroundShape

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

struct ToolbarIcon: View {
    let systemName: String
    let legacySystemName: String

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) {
            Image(systemName: systemName)
        } else {
            Image(systemName: legacySystemName)
        }
    }
}

struct NavigationTitleSubtitleModifier<LegacyContent: View>: ViewModifier {
    let title: Text
    let subtitle: Text?
    let legacyContent: () -> LegacyContent

    init(title: Text, subtitle: Text?, @ViewBuilder legacyContent: @escaping () -> LegacyContent) {
        self.title = title
        self.subtitle = subtitle
        self.legacyContent = legacyContent
    }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let subtitle {
                content.navigationTitle(title).navigationSubtitle(subtitle)
            } else {
                content.navigationTitle(title)
            }
        } else {
            content.toolbar { ToolbarItem(placement: .principal) { legacyContent() } }
        }
    }
}

private struct NavigationSubtitleIfAvailableModifier: ViewModifier {
    let subtitle: Text?

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let subtitle {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}

extension View {
    func adaptiveGlassBackground<BackgroundShape: Shape>(in shape: BackgroundShape) -> some View {
        modifier(AdaptiveGlassBackgroundModifier(shape: shape))
    }

    func navigationSubtitleIfAvailable(_ subtitle: Text?) -> some View {
        modifier(NavigationSubtitleIfAvailableModifier(subtitle: subtitle))
    }

    func navigationTitleWithSubtitle(title: Text, subtitle: Text?) -> some View {
        modifier(
            NavigationTitleSubtitleModifier(title: title, subtitle: subtitle) {
                VStack {
                    title.font(.headline)

                    if let subtitle { subtitle.font(.caption).foregroundStyle(.secondary) }
                }
            })
    }

    func navigationTitleWithSubtitle<LegacyContent: View>(
        title: Text, subtitle: Text?, @ViewBuilder legacyContent: @escaping () -> LegacyContent
    ) -> some View {
        modifier(
            NavigationTitleSubtitleModifier(
                title: title, subtitle: subtitle, legacyContent: legacyContent))
    }
}

struct ColorfulIconLabelStyle: LabelStyle {
    var color: Color
    var imageScale: Image.Scale = .medium

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.imageScale(self.imageScale).foregroundColor(.white)
                .background(
                    RoundedRectangle(cornerRadius: 7).frame(width: 28, height: 28)
                        .foregroundColor(self.color))
        }
    }
}

struct SmallTagModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(.secondary).foregroundColor(.secondary)
            .background(Color(.tertiarySystemGroupedBackground)).cornerRadius(4)
    }
}

struct GenreTagModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(.secondary).foregroundColor(.secondary)
            .background(Color(.tertiarySystemGroupedBackground)).cornerRadius(8)
    }
}

extension View {
    func smallTagStyle() -> some View { modifier(SmallTagModifier()) }

    func genreTagStyle() -> some View { modifier(GenreTagModifier()) }
}
