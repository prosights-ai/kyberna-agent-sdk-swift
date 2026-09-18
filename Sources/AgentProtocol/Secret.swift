import Foundation

/// A credential that never prints. `description` and `debugDescription` are always redacted;
/// the value is readable only through `withValue`, which callers use inside a request builder.
public struct Secret: Sendable, Equatable {
    private let storage: String
    public init(_ value: String) { storage = value }
    public var isEmpty: Bool { storage.isEmpty }
    /// Runs `body` with the plaintext. Keep the closure small and do not store the value.
    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(storage) }
    public static func == (a: Secret, b: Secret) -> Bool { a.storage == b.storage }
}

extension Secret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "Secret(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension Secret: Codable {
    public init(from decoder: Decoder) throws { storage = try decoder.singleValueContainer().decode(String.self) }
    /// Encoding a secret is refused so it cannot land in a log or fixture by accident.
    public func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Secret values are never encoded"))
    }
}
