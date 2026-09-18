import Foundation
import Synchronization

/// Owns one Claude Code CLI child process and its pipes. Knows nothing about the protocol beyond
/// "one JSON object per line"; `AgentSession` interprets the lines.
///
/// `@unchecked Sendable` (one of the SDK's two, see plan 1.5): `Process`, `Pipe`, and `FileHandle` are not
/// Sendable; every mutable field is touched only under `lock` or on one of the two serial queues. Phase 2 moves
/// this behind a host's own actor, which is when it can become a `Mutex`-based Sendable type.
public final class CLITransport: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executable: String
        public var arguments: [String]
        public var workingDirectory: String
        public var environment: [String: String]
        public var maxLineBytes: Int = 1024 * 1024
        public var recordDirectory: String?
        public var stderr: (@Sendable (String) -> Void)?
        public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String]) {
            self.executable = executable; self.arguments = arguments; self.workingDirectory = workingDirectory; self.environment = environment
        }
    }

    public enum Event: Sendable {
        case line(Data)
        case overflow(bytes: Int, limit: Int)
        case exited(status: Int32, signal: Int32?)
    }

    public let configuration: Configuration
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "agent.transport.stdin")
    /// All stdout processing and the exit notification run here, in order, so a `result` line is always
    /// delivered before `.exited` even though the pipe reader and the termination handler run on different threads.
    private let eventQueue = DispatchQueue(label: "agent.transport.events")
    private let lock = NSLock()
    private var stdinClosed = false
    private var recordStdin: FileHandle?
    private var recordStdout: FileHandle?
    private let onEvent: @Sendable (Event) -> Void

    public init(configuration: Configuration, onEvent: @escaping @Sendable (Event) -> Void) {
        self.configuration = configuration
        self.onEvent = onEvent
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func start() throws {
        let c = configuration
        process.executableURL = URL(fileURLWithPath: c.executable)
        process.arguments = c.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: c.workingDirectory)
        process.environment = c.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        if let dir = c.recordDirectory {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: c.arguments, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: dir + "/args.json"))
            for name in ["stdin.jsonl", "stdout.jsonl"] { FileManager.default.createFile(atPath: dir + "/" + name, contents: nil) }
            recordStdin = FileHandle(forWritingAtPath: dir + "/stdin.jsonl")
            recordStdout = FileHandle(forWritingAtPath: dir + "/stdout.jsonl")
        }
        if let onStderr = c.stderr {
            let errPipe = Pipe(); process.standardError = errPipe
            let buf = Mutex(LineBuffer(limit: c.maxLineBytes))
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if case .lines(let ls) = buf.withLock({ $0.append(data) }) { for l in ls { onStderr(String(data: l, encoding: .utf8) ?? "") } }
            }
        } else {
            process.standardError = FileHandle.standardError
        }
        let buf = Mutex(LineBuffer(limit: c.maxLineBytes))   // appended only on eventQueue; the Mutex satisfies the compiler's capture rules
        let onEvent = self.onEvent
        let rec = recordStdout
        let eventQueue = self.eventQueue
        let deliver: @Sendable (Data) -> Void = { chunk in
            guard !chunk.isEmpty else { return }
            switch buf.withLock({ $0.append(chunk) }) {
            case .lines(let ls):
                for l in ls { rec.map { try? $0.write(contentsOf: l + Data([0x0A])) }; onEvent(.line(l)) }
            case .overflow(let n): onEvent(.overflow(bytes: n, limit: c.maxLineBytes))
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            eventQueue.async { deliver(chunk) }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let reader = self.stdoutPipe.fileHandleForReading
            reader.readabilityHandler = nil
            let signal: Int32? = p.terminationReason == .uncaughtSignal ? p.terminationStatus : nil
            eventQueue.async {
                deliver(reader.readDataToEndOfFile())   // whatever the reader had not yet picked up
                onEvent(.exited(status: p.terminationStatus, signal: signal))
            }
        }
        try process.run()
    }

    public func write(_ line: Data) {
        let data = line.last == 0x0A ? line : line + Data([0x0A])
        writeQueue.async { [stdinPipe, recordStdin] in
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            try? recordStdin?.write(contentsOf: data)
        }
    }

    /// Closes stdin. The CLI finishes in-flight work and exits on its own.
    public func closeInput() {
        lock.lock(); let already = stdinClosed; stdinClosed = true; lock.unlock()
        guard !already else { return }
        writeQueue.sync { try? stdinPipe.fileHandleForWriting.close() }
    }

    /// SIGTERM to the child. Claude Code exits 143 and leaves the turn resumable.
    public func terminate() { if process.isRunning { process.terminate() } }

    /// SIGKILL to the child and every descendant (Bash tools, MCP servers) found via `pgrep -P`.
    public func kill() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        for child in Self.descendants(of: pid).reversed() { Darwin.kill(child, SIGKILL) }
        Darwin.kill(pid, SIGKILL)
    }

    static func descendants(of pid: Int32) -> [Int32] {
        var out: [Int32] = []
        var frontier = [pid]
        while let p = frontier.popLast() {
            let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); ps.arguments = ["-P", String(p)]
            let pipe = Pipe(); ps.standardOutput = pipe; ps.standardError = FileHandle.nullDevice
            guard (try? ps.run()) != nil else { continue }
            ps.waitUntilExit()
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") { if let c = Int32(line) { out.append(c); frontier.append(c) } }
        }
        return out
    }

    /// Runs `claude -v` with a timeout and returns the version triple, or nil if it cannot be determined.
    public static func probeVersion(executable: String, environment: [String: String]? = nil, timeout: TimeInterval = 2) -> [Int]? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = ["-v"]
        if let environment { p.environment = environment }
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let m = text.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
        return text[m].split(separator: ".").compactMap { Int($0) }
    }
}
