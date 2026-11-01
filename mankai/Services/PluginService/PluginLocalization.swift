//
//  PluginLocalization.swift
//  mankai
//
// Created by Travis XU on 1/11/2026.
//

import Foundation

/// Optional metadata overrides by app language tag.
struct PluginLocalization: Codable {
    var name: String?
    var description: String?
    var authors: [String]?
    var repository: String?
    var icon: String?
    var homePage: String?
}

extension String {
    private static let chapterLabelPatterns: [(regex: NSRegularExpression, isVolume: Bool)] = {
        let number = #"([0-9０-９]+(?:[.．][0-9０-９]+)?|[〇零一二三四五六七八九十百千万萬亿億兆两兩]+)"#
        let patterns = [
            (#"^\s*(?:vol(?:ume)?[.．]?|卷|巻|ボリューム)\s*"# + number + #"(.*)$"#, true),
            (#"^\s*(?:ch(?:apter)?[.．]?|章节|章節|チャプター)\s*"# + number + #"(.*)$"#, false),
            (#"^\s*第?\s*"# + number + #"\s*[卷巻册冊](.*)$"#, true),
            (#"^\s*第?\s*"# + number + #"\s*[话話章回节節](.*)$"#, false)
        ]
        return patterns.compactMap { pattern, isVolume in
            guard
                let regex = try? NSRegularExpression(
                    pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            else { return nil }
            return (regex, isVolume)
        }
    }()

    /// Localizes numbered labels while preserving any trailing chapter or group title.
    var localizedChapterLabel: String {
        let range = NSRange(startIndex..<endIndex, in: self)

        for (regex, isVolume) in Self.chapterLabelPatterns {
            guard let match = regex.firstMatch(in: self, range: range),
                let numberRange = Range(match.range(at: 1), in: self),
                let suffixRange = Range(match.range(at: 2), in: self)
            else { continue }

            let format =
                isVolume
                ? String(localized: "volumeLabelFormat") : String(localized: "chapterLabelFormat")
            let label = String(format: format, String(self[numberRange]))
            let suffix = String(self[suffixRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? label : "\(label) \(suffix)"
        }

        return self
    }
}
