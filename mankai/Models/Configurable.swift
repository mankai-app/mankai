//
//  Configurable.swift
//  mankai
//
//  Created by Travis XU on 27/9/2026.
//

import Foundation
import ReerCodable

enum ConfigType: String, Codable {
    case text
    case password
    case number
    case slider
    case boolean
    case select

    func parseValue(_ stringValue: String) -> Any {
        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self { case .boolean: return trimmed.lowercased() == "true" || trimmed == "1"
            case .number, .slider:
                if let intValue = Int(trimmed) { return intValue }
                return Double(trimmed) ?? trimmed
            case .text, .password, .select: return trimmed
        }
    }
}

@Codable struct Config {
    var key: String
    var name: String
    var description: String?
    var type: ConfigType
    var options: [String]?
    var min: Double?
    var max: Double?
    var step: Double?

    @CodingKey("defaultValue") private var codedDefaultValue: AnyCodable?

    var defaultValue: Any {
        get { codedDefaultValue?.value ?? NSNull() }
        set { codedDefaultValue = AnyCodable(newValue) }
    }

    init(
        key: String, name: String, description: String? = nil, type: ConfigType, defaultValue: Any,
        options: [String]? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil
    ) {
        self.key = key
        self.name = name
        self.description = description
        self.type = type
        self.options = options
        self.min = min
        self.max = max
        self.step = step
        codedDefaultValue = AnyCodable(defaultValue)
    }
}

@Codable struct ConfigValue {
    var key: String

    @CodingKey("value") private var codedValue: AnyCodable

    var value: Any {
        get { codedValue.value }
        set { codedValue = AnyCodable(newValue) }
    }

    init(key: String, value: Any) {
        self.key = key
        codedValue = AnyCodable(value)
    }
}

@MainActor protocol Configurable: AnyObject {
    var configs: [Config] { get }
    var configValues: [ConfigValue] { get }

    func getConfig(_ key: String) -> Any
    func setConfig(key: String, value: Any) throws
    func resetConfigs() throws
}
