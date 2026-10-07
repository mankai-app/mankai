//
//  OpdsParser.swift
//  mankai
//
//  Created by Travis XU on 20/8/2026.
//

import Foundation
import SWXMLHash

enum OpdsEntry: Sendable {
    case navigation(OpdsNavigationEntry)
    case book(OpdsBookEntry)
}

struct OpdsNavigationEntry: Sendable {
    let id: String?
    let title: String?
    let url: URL
}

enum OpdsMediaType: Codable, Sendable {
    case regular(url: URL, type: String?)
    case pse(urlTemplate: URL, pageCount: Int)
}

struct OpdsBookEntry: Codable, Sendable {
    let id: String
    let title: String?
    let authors: [String]
    let description: String?
    let genres: [String]
    let coverURL: URL?
    let mediaType: OpdsMediaType
}

struct OpdsFeed: Sendable {
    let metadata: OpdsNavigationEntry
    let entries: [OpdsEntry]
}

enum OpdsParser {
    private static let acquisitionRelation = "http://opds-spec.org/acquisition"
    private static let imageRelation = "http://opds-spec.org/image"
    private static let thumbnailRelation = "http://opds-spec.org/image/thumbnail"
    private static let pageStreamingRelation = "http://vaemendis.net/opds-pse/stream"

    static func parse(_ data: Data, baseURL: URL? = nil) throws -> OpdsFeed {
        let document =
            XMLHash.config { config in
                config.detectParsingErrors = true
                config.shouldProcessNamespaces = true
            }
            .parse(data)

        if case .parsingError = document {
            throw MankaiErrorCode.browseOpdsInvalidDocument.makeError()
        }

        guard document.children.count == 1, let feed = document.children.first?.element,
            localName(feed.name) == "feed"
        else { throw MankaiErrorCode.browseOpdsInvalidDocument.makeError() }

        let feedChildren = feed.children.compactMap { $0 as? SWXMLHash.XMLElement }
        let feedTitleValue = feedChildren.first(where: { localName($0.name) == "title" })?
            .recursiveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let feedTitle = feedTitleValue?.isEmpty == false ? feedTitleValue : nil

        let feedIdValue = feedChildren.first(where: { localName($0.name) == "id" })?.recursiveText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var selfURL = baseURL
        for link in feedChildren where localName(link.name) == "link" {
            guard attribute(link, named: "rel")?.lowercased() == "self",
                let href = attribute(link, named: "href"),
                let url = resolvedURL(href, for: link, baseURL: baseURL)
            else { continue }
            selfURL = url
            break
        }
        guard let selfURL else { throw MankaiErrorCode.browseOpdsInvalidDocument.makeError() }

        let feedEntry = OpdsNavigationEntry(
            id: feedIdValue?.isEmpty == false ? feedIdValue : nil, title: feedTitle, url: selfURL)
        var entries: [OpdsEntry] = []

        for child in document.children.first?.children ?? [] {
            guard let entry = child.element, localName(entry.name) == "entry" else { continue }

            let children = child.children.compactMap(\.element)
            let titleValue = children.first(where: { localName($0.name) == "title" })?.recursiveText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = titleValue?.isEmpty == false ? titleValue : nil

            let links = children.filter { localName($0.name) == "link" }
            let hasAcquisitionRelation = links.contains { link in
                relation(of: link)?.hasPrefix(acquisitionRelation) == true
            }
            let hasPageStreamingRelation = links.contains {
                relation(of: $0) == pageStreamingRelation
            }

            if hasAcquisitionRelation || hasPageStreamingRelation {
                guard let idElement = children.first(where: { localName($0.name) == "id" }) else {
                    continue
                }
                let id = idElement.recursiveText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }

                let regularMediaType = links.lazy
                    .compactMap { link -> OpdsMediaType? in
                        guard relation(of: link)?.hasPrefix(acquisitionRelation) == true,
                            let href = attribute(link, named: "href"),
                            let url = resolvedURL(href, for: link, baseURL: baseURL)
                        else { return nil }

                        return .regular(url: url, type: attribute(link, named: "type"))
                    }
                    .first
                let pageStreamingMediaType = links.lazy
                    .compactMap { link -> OpdsMediaType? in
                        guard relation(of: link) == pageStreamingRelation,
                            let href = attribute(link, named: "href")?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                            href.contains("{pageNumber}"),
                            let urlTemplate = resolvedURL(href, for: link, baseURL: baseURL),
                            let countValue = attribute(link, named: "count")?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                            let pageCount = Int(countValue), pageCount > 0
                        else { return nil }

                        return .pse(urlTemplate: urlTemplate, pageCount: pageCount)
                    }
                    .first

                guard let mediaType = pageStreamingMediaType ?? regularMediaType else { continue }

                var authors: [String] = []
                for author in children where localName(author.name) == "author" {
                    guard
                        let name = author.children.compactMap({ $0 as? SWXMLHash.XMLElement })
                            .first(where: { localName($0.name) == "name" })
                    else { continue }
                    let value = name.recursiveText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { authors.append(value) }
                }

                var description: String?
                if let content = children.first(where: { localName($0.name) == "content" }) {
                    let value = content.recursiveText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !value.isEmpty { description = value }
                }
                if description == nil,
                    let summary = children.first(where: { localName($0.name) == "summary" })
                {
                    let value = summary.recursiveText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !value.isEmpty { description = value }
                }

                var genres: [String] = []
                for category in children where localName(category.name) == "category" {
                    guard
                        let term = attribute(category, named: "term")?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty
                    else { continue }
                    genres.append(term)
                }

                var coverURL: URL?
                for link in links {
                    guard relation(of: link) == imageRelation,
                        let href = attribute(link, named: "href"),
                        let url = resolvedURL(href, for: link, baseURL: baseURL)
                    else { continue }
                    coverURL = url
                    break
                }

                if coverURL == nil {
                    for link in links {
                        guard relation(of: link) == thumbnailRelation,
                            let href = attribute(link, named: "href"),
                            let url = resolvedURL(href, for: link, baseURL: baseURL)
                        else { continue }
                        coverURL = url
                        break
                    }
                }

                entries.append(
                    .book(
                        OpdsBookEntry(
                            id: id, title: title, authors: authors, description: description,
                            genres: genres, coverURL: coverURL, mediaType: mediaType)))
                continue
            }

            guard
                let navigationLink = links.first(where: { link in
                    let relation = relation(of: link)
                    guard relation?.hasPrefix(imageRelation) != true,
                        let href = attribute(link, named: "href")
                    else { return false }
                    return resolvedURL(href, for: link, baseURL: baseURL) != nil
                }), let navigationHref = attribute(navigationLink, named: "href"),
                let navigationURL = resolvedURL(
                    navigationHref, for: navigationLink, baseURL: baseURL)
            else { continue }

            let navigationIdValue = children.first(where: { localName($0.name) == "id" })?
                .recursiveText.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(
                .navigation(
                    OpdsNavigationEntry(
                        id: navigationIdValue?.isEmpty == false ? navigationIdValue : nil,
                        title: title, url: navigationURL)))
        }

        return OpdsFeed(metadata: feedEntry, entries: entries)
    }

    private static func relation(of element: SWXMLHash.XMLElement) -> String? {
        attribute(element, named: "rel")?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name)).lowercased()
    }

    private static func attribute(_ element: SWXMLHash.XMLElement, named name: String) -> String? {
        if let value = element.attribute(by: name)?.text { return value }

        return element.allAttributes.values.first { localName($0.name) == name.lowercased() }?.text
    }

    private static func resolvedURL(
        _ value: String, for element: SWXMLHash.XMLElement, baseURL: URL?
    ) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var xmlBases: [String] = []
        var currentElement: SWXMLHash.XMLElement? = element
        while let current = currentElement {
            if let xmlBase = attribute(current, named: "base")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !xmlBase.isEmpty
            {
                xmlBases.append(xmlBase)
            }
            currentElement = current.parent
        }

        var effectiveBaseURL = baseURL
        for xmlBase in xmlBases.reversed() {
            if let currentBaseURL = effectiveBaseURL {
                effectiveBaseURL = URL(string: xmlBase, relativeTo: currentBaseURL)?.absoluteURL
            } else {
                effectiveBaseURL = URL(string: xmlBase)
            }
        }

        if let effectiveBaseURL {
            return URL(string: value, relativeTo: effectiveBaseURL)?.absoluteURL
        }
        return URL(string: value)
    }
}
