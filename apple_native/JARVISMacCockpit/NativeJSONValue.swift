import Foundation

enum NativeJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([NativeJSONValue])
    case object([String: NativeJSONValue])

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var values: [NativeJSONValue] = []
            while !array.isAtEnd {
                values.append(try array.decode(NativeJSONValue.self))
            }
            self = .array(values)
            return
        }

        if let object = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var values: [String: NativeJSONValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(NativeJSONValue.self, forKey: key)
            }
            self = .object(values)
            return
        }

        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for key in values.keys.sorted() {
                try container.encode(values[key], forKey: DynamicCodingKey(stringValue: key))
            }
        }
    }

    static func fromEncodable<Value: Encodable>(_ value: Value) throws -> NativeJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(NativeJSONValue.self, from: data)
    }

    var objectValue: [String: NativeJSONValue]? {
        if case .object(let values) = self {
            return values
        }
        return nil
    }

    var arrayValue: [NativeJSONValue]? {
        if case .array(let values) = self {
            return values
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    subscript(key: String) -> NativeJSONValue? {
        objectValue?[key]
    }
}

private struct DynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
