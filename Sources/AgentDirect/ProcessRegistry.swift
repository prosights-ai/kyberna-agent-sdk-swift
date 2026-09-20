import Foundation
import Darwin
import Synchronization

/// Every process a tool spawns, so an interrupt can end them all (plan Phase 8, interrupt contract item 2).
/// Children are spawned with `posix_spawn` into their own process group, so `killpg` reaches whatever they
/// spawned in turn. `terminateAll` sends SIGTERM to each group, waits `grace`, then SIGKILL.
///
/// Tools reach this only through `ToolContext.run`; a `Process` a tool creates directly is outside the registry
/// and, in debug builds, `auditUnregisteredChildren` reports it after the tool returns.
public final class ProcessRegistry: Sendable {
    private struct Entry { var pid: pid_t; var command: String }
    private let entries = Mutex<[pid_t: Entry]>([:])

    public init() {}

    /// Process ids currently registered.
    public var registeredPIDs: [pid_t] { entries.withLock { $0.keys.sorted() } }

    func register(pid: pid_t, command: String) { entries.withLock { $0[pid] = Entry(pid: pid, command: command) } }
    func unregister(pid: pid_t) { entries.withLock { _ = $0.removeValue(forKey: pid) } }

    /// SIGTERM to every registered process group, `grace` seconds, then SIGKILL to those still registered
    /// (the same two-step the CLI transport uses). Returns the pids that needed SIGKILL.
    @discardableResult
    public func terminateAll(grace: TimeInterval = 2) async -> [pid_t] {
        let first = registeredPIDs
        guard !first.isEmpty else { return [] }
        for pid in first { killpg(pid, SIGTERM) }
        let deadline = ContinuousClock.now + .seconds(grace)
        while ContinuousClock.now < deadline, !registeredPIDs.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        let remaining = registeredPIDs
        for pid in remaining { killpg(pid, SIGKILL) }
        return remaining
    }

    /// Children of this process that no tool registered. Debug builds assert on a non-empty answer after a tool
    /// returns (plan Phase 8 security checkpoint: no tool can spawn a process outside the registry).
    public func unregisteredChildren() -> [pid_t] {
        let me = getpid()
        var buffer = [pid_t](repeating: 0, count: 1024)
        let bytes = Int32(buffer.count * MemoryLayout<pid_t>.stride)
        let filled = buffer.withUnsafeMutableBytes { proc_listchildpids(me, $0.baseAddress, bytes) }
        guard filled > 0 else { return [] }
        let count = Int(filled) / MemoryLayout<pid_t>.stride
        let known = Set(registeredPIDs)
        return Array(buffer[0..<count]).filter { !known.contains($0) && $0 > 0 }
    }
}

/// What a tool gets from `ToolContext.run`.
public struct CommandOutput: Sendable, Equatable {
    public var status: Int32
    /// The signal that ended the process, when one did.
    public var signal: Int32?
    public var stdout: String
    public var stderr: String
    /// True when stdout or stderr hit `maxOutputBytes` and was cut.
    public var truncated: Bool
    public var timedOut: Bool
    public init(status: Int32, signal: Int32? = nil, stdout: String, stderr: String, truncated: Bool = false, timedOut: Bool = false) {
        self.status = status; self.signal = signal; self.stdout = stdout; self.stderr = stderr; self.truncated = truncated; self.timedOut = timedOut
    }
}

/// The per-call context a tool runs in. `run` is the only sanctioned way for a tool to start a process.
public struct ToolContext: Sendable {
    public var registry: ProcessRegistry
    public var toolUseId: String
    public var workingDirectory: String?
    /// Cap on each of stdout and stderr (64 KiB by default, plan 9.5).
    public var maxOutputBytes: Int
    /// Environment the child receives; nothing is inherited beyond this (plan section 5: environment allowlist).
    public var environment: [String: String]

    public init(registry: ProcessRegistry, toolUseId: String, workingDirectory: String? = nil, maxOutputBytes: Int = 64 << 10,
                environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]) {
        self.registry = registry; self.toolUseId = toolUseId; self.workingDirectory = workingDirectory
        self.maxOutputBytes = maxOutputBytes; self.environment = environment
    }

    /// The context of the tool call running on this task, set by `ToolExecutor` for the handler's duration.
    @TaskLocal public static var current: ToolContext?

    /// Runs `command` through `/bin/sh -c`, registered in the registry, capped and bounded by `timeout`.
    public func run(command: String, timeout: TimeInterval = 30) async throws -> CommandOutput {
        try await run("/bin/sh", ["-c", command], timeout: timeout)
    }

    /// Spawns `executable` with `arguments` in its own process group, registered for the call's duration. Output is
    /// capped at `maxOutputBytes` per stream. On `timeout` the group gets SIGTERM, then SIGKILL after a second;
    /// on cancellation of the calling task the same, and `CancellationError` is rethrown.
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandOutput {
        let child = try SpawnedProcess.spawn(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory, cap: maxOutputBytes)
        registry.register(pid: child.pid, command: ([executable] + arguments).joined(separator: " "))
        defer { registry.unregister(pid: child.pid) }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandOutput?.self) { group in
                group.addTask { try await child.output.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                guard let first = try await group.next() else { return CommandOutput(status: -1, stdout: "", stderr: "") }
                if let output = first { group.cancelAll(); return output }
                // The timer won: end the group, then report what the single reader collected.
                child.terminate(grace: 1)
                group.cancelAll()
                var output = try await child.output.value
                output.timedOut = true
                return output
            }
        } onCancel: {
            child.terminate(grace: 1)
        }
    }
}

/// A child started with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`, with pipes for stdout and stderr.
final class SpawnedProcess: Sendable {
    let pid: pid_t
    /// Reads both pipes to EOF (each capped) and reaps the child, once; started at spawn so a chatty child never
    /// blocks on a full pipe.
    let output: Task<CommandOutput, Error>

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32, cap: Int) {
        self.pid = pid
        output = Task.detached { try await Self.collect(pid: pid, stdoutFD: stdoutFD, stderrFD: stderrFD, cap: cap) }
    }

    static func spawn(executable: String, arguments: [String], environment: [String: String], workingDirectory: String?, cap: Int) throws -> SpawnedProcess {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw ProviderError.transport("pipe failed: \(errno)") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        for fd in [outPipe[0], outPipe[1], errPipe[0], errPipe[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
        if let workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ProviderError.transport("posix_spawn \(executable): \(String(cString: strerror(rc)))")
        }
        return SpawnedProcess(pid: pid, stdoutFD: outPipe[0], stderrFD: errPipe[0], cap: cap)
    }

    /// SIGTERM to the group, then SIGKILL after `grace`, off the calling thread.
    func terminate(grace: TimeInterval) {
        let pid = pid
        killpg(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { killpg(pid, SIGKILL) }
    }

    private static func collect(pid: pid_t, stdoutFD: Int32, stderrFD: Int32, cap: Int) async throws -> CommandOutput {
        let (out, outCut) = try await read(fd: stdoutFD, cap: cap)
        let (err, errCut) = try await read(fd: stderrFD, cap: cap)
        var status: Int32 = 0
        var rc: pid_t
        repeat { rc = waitpid(pid, &status, 0) } while rc == -1 && errno == EINTR
        let exited = (status & 0x7F) == 0
        return CommandOutput(status: exited ? (status >> 8) & 0xFF : -1, signal: exited ? nil : status & 0x7F,
                             stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), truncated: outCut || errCut)
    }

    /// Reads to EOF on a utility thread; bytes past `cap` are drained and dropped.
    private static func read(fd: Int32, cap: Int) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var data = Data(), total = 0
                var buffer = [UInt8](repeating: 0, count: 16 << 10)
                while true {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n > 0 {
                        total += n
                        if data.count < cap { data.append(contentsOf: buffer[0..<min(n, cap - data.count)]) }
                    } else if n == 0 || errno != EINTR { break }
                }
                let cut = total > cap
                close(fd)
                continuation.resume(returning: (data, cut))
            }
        }
    }
}
