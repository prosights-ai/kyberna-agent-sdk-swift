import Foundation

/// The fake CLI as a function, so an executable in any package is one line: `FakeCLIMain.run()`.
///
/// fake-claude replays a recorded fixture over stdin and stdout so an SDK can be tested without the real CLI.
/// Usage: `FAKE_CLAUDE_FIXTURE=/path/to/fixture-dir fake-claude [any args]`; the args are compared to the
/// fixture's args.json unless `FAKE_CLAUDE_IGNORE_ARGS` is set, `-v` prints the recorded version so version
/// probes work, and `FAKE_CLAUDE_LENIENT` relaxes the byte-for-byte check of what the SDK writes.
public enum FakeCLIMain {
    public static func run() -> Never {

        // fake-claude: replays a recorded fixture over stdin/stdout so an SDK can be tested without the real CLI.
        // Usage: FAKE_CLAUDE_FIXTURE=/path/to/fixture-dir fake-claude [any args]   (args are compared to args.json)
        // `fake-claude -v` prints the version recorded in meta.json so version probes work.
        setvbuf(stdout, nil, _IOLBF, 0)
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FAKE_CLAUDE_FIXTURE"] else { FileHandle.standardError.write(Data("FAKE_CLAUDE_FIXTURE not set\n".utf8)); exit(2) }
        let fixture: Fixture
        do { fixture = try Fixture(directory: dir) } catch { FileHandle.standardError.write(Data("cannot load fixture: \(error)\n".utf8)); exit(2) }
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["-v"] || args == ["--version"] {
            print("\(fixture.meta["claude_code_version"]?.stringValue ?? "0.0.0") (Claude Code, fake)"); exit(0)
        }
        if args != fixture.arguments && env["FAKE_CLAUDE_IGNORE_ARGS"] == nil {
            FileHandle.standardError.write(Data("argument mismatch\n expected: \(fixture.arguments)\n actual:   \(args)\n".utf8)); exit(4)
        }
        let runner = FakeCLIRunner(script: FakeCLIScript(fixture: fixture))
        runner.strict = env["FAKE_CLAUDE_LENIENT"] == nil
        let status = runner.run(readLine: { readLine(strippingNewline: true) }, writeLine: { print($0) })
        if !runner.mismatches.isEmpty { FileHandle.standardError.write(Data((runner.mismatches.joined(separator: "\n") + "\n").utf8)) }
        exit(status)

    }
}
