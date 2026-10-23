import Foundation

/// Any JSON value. Holds manifest keys this version does not know so they survive open → save (§4.5).
public enum JSONValue: Hashable, Sendable, Codable {
    /// `null`.
    case null
    /// `true` / `false`.
    case bool(Bool)
    /// A number with no fraction that fits `Int64` (kept exact).
    case integer(Int64)
    /// Any other number.
    case double(Double)
    /// A string.
    case string(String)
    /// An array.
    case array([JSONValue])
    /// An object.
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .integer(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = try .object(c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .integer(v): try c.encode(v)
        case let .double(v): try c.encode(v)
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }
}

/// Coding key for arbitrary object keys (manifest passthrough).
struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? {
        nil
    }

    init(_ string: String) {
        stringValue = string
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

extension KeyedDecodingContainer<AnyCodingKey> {
    /// Every key not in `known`, decoded as ``JSONValue``.
    func unknownKeys(excluding known: Set<String>) throws -> [String: JSONValue] {
        var extra: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return extra
    }
}

extension KeyedEncodingContainer<AnyCodingKey> {
    /// Writes passthrough keys. Known keys win: an `extra` entry never overwrites a typed field.
    mutating func encodeUnknownKeys(_ extra: [String: JSONValue], excluding known: Set<String>) throws {
        for (key, value) in extra where !known.contains(key) {
            try encode(value, forKey: AnyCodingKey(key))
        }
    }
}
