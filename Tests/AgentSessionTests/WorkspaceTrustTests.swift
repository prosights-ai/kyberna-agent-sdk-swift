import Testing
import Foundation
import AgentProtocol
@testable import AgentSession

struct WorkspaceTrustTests {
    func temp() throws -> (config: String, dir: String) {
        let base = NSTemporaryDirectory() + "kyb-trust-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base + "/proj", withIntermediateDirectories: true)
        return (base + "/claude.json", base + "/proj")
    }

    @Test func recordsTheSameFlagTheCLIWrites() throws {
        let (cfg, dir) = try temp()
        try Data(#"{"userID":"u1","projects":{"\#(dir)":{"allowedTools":["Read"]}},"theme":"dark"}"#.utf8).write(to: URL(fileURLWithPath: cfg))
        let t = WorkspaceTrust(configPath: cfg)
        #expect(t.status(of: dir) == .untrusted)
        #expect(try t.record(dir) == .trusted)
        #expect(t.status(of: dir + "/") == .trusted)
        let root = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: cfg)))
        #expect(root["userID"]?.stringValue == "u1" && root["theme"]?.stringValue == "dark")
        #expect(root["projects"]?[dir]?["allowedTools"]?.arrayValue?.count == 1)
        #expect(root["projects"]?[dir]?["hasTrustDialogAccepted"]?.boolValue == true)
        let realpath = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        #expect(root["projects"]?[realpath]?["hasTrustDialogAccepted"]?.boolValue == true)
        let perms = try FileManager.default.attributesOfItem(atPath: cfg)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func createsFileWhenMissing() throws {
        let (cfg, dir) = try temp()
        let t = WorkspaceTrust(configPath: cfg)
        #expect(try t.record(dir) == .trusted)
        #expect(t.status(of: dir) == .trusted)
    }

    @Test func homeDirectoryIsNeverPersisted() throws {
        let (cfg, _) = try temp()
        let t = WorkspaceTrust(configPath: cfg)
        #expect(try t.record(NSHomeDirectory()) == .homeDirectoryNeverPersisted)
        #expect(!FileManager.default.fileExists(atPath: cfg))
        #expect(t.status(of: "~") == .homeDirectoryNeverPersisted)
    }
}
