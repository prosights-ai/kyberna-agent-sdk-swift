import Foundation

/// A JSON document as a Swift value. Used wherever the wire carries open-ended JSON
/// (tool inputs, hook inputs, provider payloads) so public API never exposes `[String: Any]`.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int? { if case .number(let n) = self, n.rounded() == n { return Int(n) }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
    subscript(key: String) -> JSONValue? { objectValue?[key] }
    subscript(index: Int) -> JSONValue? { guard let a = arrayValue, a.indices.contains(index) else { return nil }; return a[index] }

    /// Bridges a `JSONSerialization` object. Anything unrepresentable becomes `.null`.
    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let b as Bool where type(of: any!) == type(of: NSNumber(value: true)) && (any as? NSNumber)?.objCType.pointee == 99: self = .bool(b)
        case let n as NSNumber:
            // NSNumber booleans report objCType "c"; treat those as bool, everything else as number.
            if n.objCType.pointee == 99 { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    /// The `JSONSerialization`-compatible object.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? Int64(n) as Any : n as Any
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o): return o.mapValues { $0.anyValue }
        }
    }

    /// Parses JSON text. Numbers stay doubles; `true`/`false` stay booleans (via the JSONSerialization bridge).
    init(data: Data) throws { self = JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }
    /// Pretty JSON with sorted keys, for files a person may open (such as `~/.claude.json`).
    func data() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try enc.encode(self)
    }
    /// Compact JSON text with sorted keys, stable across runs (needed for hashing approvals and for prompt caches).
    var canonicalJSON: String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: (try? enc.encode(self)) ?? Data("null".utf8), encoding: .utf8) ?? "null"
    }
}
