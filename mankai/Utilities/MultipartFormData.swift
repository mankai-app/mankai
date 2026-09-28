//
//  MultipartFormData.swift
//  mankai
//
//  Created by Travis XU on 28/9/2026.
//

import Foundation

struct MultipartFormData: Sendable {
    private struct Part: Sendable {
        let name: String
        let filename: String?
        let contentType: String?
        let data: Data
    }

    let boundary: String
    private var parts: [Part] = []

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    init(boundary: String = "MankaiBoundary-\(UUID().uuidString)") { self.boundary = boundary }

    mutating func addJSON<Value: Encodable>(
        _ value: Value, name: String, encoder: JSONEncoder = JSONEncoder()
    ) throws { add(try encoder.encode(value), name: name, contentType: "application/json") }

    mutating func addFile(_ data: Data, name: String, filename: String, contentType: String) {
        add(data, name: name, filename: filename, contentType: contentType)
    }

    mutating func add(
        _ data: Data, name: String, filename: String? = nil, contentType: String? = nil
    ) { parts.append(Part(name: name, filename: filename, contentType: contentType, data: data)) }

    func encodedData() -> Data {
        var result = Data()
        for part in parts {
            result.append(Data("--\(boundary)\r\n".utf8))

            var disposition = "Content-Disposition: form-data; name=\"\(Self.escape(part.name))\""
            if let filename = part.filename {
                disposition += "; filename=\"\(Self.escape(filename))\""
            }
            result.append(Data("\(disposition)\r\n".utf8))

            if let contentType = part.contentType {
                result.append(Data("Content-Type: \(contentType)\r\n".utf8))
            }
            result.append(Data("\r\n".utf8))
            result.append(part.data)
            result.append(Data("\r\n".utf8))
        }
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
