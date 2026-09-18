import Foundation

/// The recorded conversations from the shared `SDKs/protocol/fixtures` folder, copied into this bundle at build
/// time so a test in this package or in any package that depends on it finds them the same way (plan section
/// 1.5: golden fixtures, language neutral, one copy read by every SDK).
public enum Fixtures {
    /// `.../fixtures`, holding `cli/<claude code version>/<scenario>/`.
    public static var root: URL { Bundle.module.resourceURL!.appendingPathComponent("fixtures") }
    /// `.../Fixtures/cli/<version>`.
    public static func cli(_ version: String) -> URL { root.appendingPathComponent("cli/" + version) }
    /// `.../Fixtures/cli/<version>/<scenario>`.
    public static func scenario(_ name: String, version: String) -> URL { cli(version).appendingPathComponent(name) }
    /// The recorded versions, newest last.
    public static var versions: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cli").path)) ?? []
        return names.sorted { a, b in
            let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
            return x.lexicographicallyPrecedes(y)
        }
    }
}
