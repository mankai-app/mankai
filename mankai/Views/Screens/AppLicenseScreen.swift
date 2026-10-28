//
//  AppLicenseScreen.swift
//  mankai
//
//  Created by Travis XU on 3/8/2026.
//

import SwiftUI

struct AppLicenseScreen: View {
    private let licenseText: String?

    init(bundle: Bundle = .main) {
        guard let licenseURL = bundle.url(forResource: "LICENSE", withExtension: nil) else {
            licenseText = nil
            return
        }

        licenseText = try? String(contentsOf: licenseURL, encoding: .utf8)
    }

    var body: some View {
        Group {
            if let licenseText {
                ScrollView {
                    Text(licenseText).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity).padding()
                }
                .background(Color(.systemGroupedBackground))
            } else {
                ContentUnavailableView(
                    "licenseUnavailable", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle("license").navigationBarTitleDisplayMode(.inline)
    }
}
