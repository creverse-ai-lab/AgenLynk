import Foundation

/// Every copy of the app macOS ever saw — a mounted DMG, a temp folder, an old
/// build — stays in the Launch Services database under its bundle identifier,
/// long after the copy is gone. Dozens of dead copies of one identifier is how
/// the menu bar item went missing before 0.5.0 beta 1 moved to a new
/// identifier. Once per installed build (so right after an update), drop the
/// records nobody can launch any more.
enum LaunchServicesHygiene {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let identifiers: Set<String> = [
        "ai.creverse.agenlynk",
        "ai.creverse.agenlynk.pet",
        LegacyDefaultsImport.legacyDomain,
        LegacyDefaultsImport.legacyDomain + ".pet"
    ]
    static let markerKey = "monitor.launchServicesHygieneBuild"
    /// Places a copy only passes through: DMG mounts and temp folders.
    static let transientPrefixes = ["/Volumes/", "/private/var/folders/", "/private/tmp/", "/tmp/"]

    static func runOncePerBuild(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        let info = bundle.infoDictionary
        let build = "\(info?["CFBundleShortVersionString"] as? String ?? "?")+\(info?["CFBundleVersion"] as? String ?? "?")"
        guard defaults.string(forKey: markerKey) != build else { return }
        let running = bundle.bundleURL.standardizedFileURL.path
        // Not .background: that QoS throttles the ~3s dump into minutes.
        Task.detached(priority: .utility) {
            guard let dump = run(lsregister, ["-dump"]) else { return }
            let fileManager = FileManager.default
            for path in stalePaths(in: dump, keeping: running, exists: { fileManager.fileExists(atPath: $0) }) {
                _ = run(lsregister, ["-u", path])
            }
            defaults.set(build, forKey: markerKey)
        }
    }

    /// Registered paths for our identifiers that are gone, or that sit in a
    /// transient place, other than the running app and what it contains.
    static func stalePaths(in dump: String, keeping running: String, exists: (String) -> Bool) -> [String] {
        var stale: [String] = []
        var path: String?
        var identifier: String?
        func flush() {
            defer { path = nil; identifier = nil }
            guard let path, let identifier, identifiers.contains(identifier),
                  path != running, !path.hasPrefix(running + "/") else { return }
            if !exists(path) || transientPrefixes.contains(where: path.hasPrefix) {
                stale.append(path)
            }
        }
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("-----") {
                flush()
            } else if path == nil, line.hasPrefix("path:") {
                path = value(of: line).replacingOccurrences(of: #" \(0x[0-9a-f]+\)$"#, with: "", options: .regularExpression)
            } else if identifier == nil, line.hasPrefix("identifier:") {
                identifier = value(of: line)
            }
        }
        flush()
        return Array(Set(stale)).sorted()
    }

    private static func value(of line: Substring) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
