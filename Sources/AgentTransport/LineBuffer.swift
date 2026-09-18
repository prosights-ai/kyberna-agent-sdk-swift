import Foundation

/// Accumulates bytes and returns complete newline-terminated lines. A value type: the owner serializes access
/// (CLITransport appends only on its event queue).
public struct LineBuffer: Sendable {
    private var data = Data()
    public let limit: Int
    public init(limit: Int = 1024 * 1024) { self.limit = limit }

    public enum Outcome: Sendable { case lines([Data]), overflow(bytes: Int) }

    /// Appends `chunk`; returns complete lines, or `.overflow` when an unterminated line exceeds `limit`
    /// (the partial line is discarded, mirroring the SDK's max_buffer_size behavior).
    public mutating func append(_ chunk: Data) -> Outcome {
        data.append(chunk)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(data.subdata(in: data.startIndex..<nl))
            data.removeSubrange(data.startIndex...nl)
        }
        if lines.isEmpty, data.count > limit {
            let n = data.count; data.removeAll(keepingCapacity: false)
            return .overflow(bytes: n)
        }
        return .lines(lines)
    }
}
