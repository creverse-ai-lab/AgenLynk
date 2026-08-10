import Foundation

// Locates and validates the Node runtime used to launch the Monitor sidecar
// and the installer/bootstrap script.
//
// Packaged builds (an app bundle carrying a runtime seed under
// Contents/Resources/runtime/node/bin/node) must resolve Node and every
// script from the *installed* runtime at ~/.acp-gateway/runtime — never the
// app bundle itself, which is seed input only (see TODO.md's fixed
// single-install-path boundary and RuntimeProvisioner, which copies the seed
// there). A Settings/ACP_GATEWAY_NODE override therefore cannot bypass the
// installed runtime in a packaged build; those overrides only apply when
// running from a source-tree checkout that carries no bundled seed at all.
enum BundledRuntimeError: LocalizedError {
    case nodeNotFound
    case nodeVersionTooOld(found: String)
    case nodeVersionCheckFailed(String)
    case resourceNotFound(String)
    case runtimeNotInstalled

    var errorDescription: String? {
        switch self {
        case .nodeNotFound:
            "Node 22 이상을 찾지 못했습니다. Lynk를 다시 설치하거나 Settings에서 Node 실행 파일 경로를 지정하세요."
        case let .nodeVersionTooOld(found):
            "Node \(found)은 너무 오래되었습니다. Node 22 이상이 필요합니다."
        case let .nodeVersionCheckFailed(message):
            "Node 버전을 확인하지 못했습니다: \(message)"
        case let .resourceNotFound(path):
            "필요한 실행 파일을 찾지 못했습니다: \(path)"
        case .runtimeNotInstalled:
            "설치된 Gateway runtime을 찾지 못했습니다. Lynk를 다시 시작해 설치를 완료하세요."
        }
    }
}

struct InstalledRuntimePointer: Equatable {
    let runtimeRoot: URL
    let gatewayVersion: String
    let gatewayBuildId: String
}

enum BundledRuntime {
    static let minimumMajorVersion = 22

    static func locateNode(override: String = "") throws -> URL {
        if isPackagedDistribution() {
            guard let installed = readCurrentRuntime() else { throw BundledRuntimeError.runtimeNotInstalled }
            let node = installed.runtimeRoot.appendingPathComponent("node/bin/node")
            guard FileManager.default.isExecutableFile(atPath: node.path) else {
                throw BundledRuntimeError.runtimeNotInstalled
            }
            return node
        }

        // Source-tree development fallback only: no bundled runtime shipped,
        // so an explicit override or a PATH Node is the only option.
        let environmentOverride = ProcessInfo.processInfo.environment["ACP_GATEWAY_NODE"] ?? ""
        if let explicit = [override, environmentOverride].first(where: { !$0.isEmpty }),
           FileManager.default.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BundledRuntimeError.nodeNotFound
        }
        return URL(fileURLWithPath: path)
    }

    static func bundledNodeURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("runtime/node/bin/node")
    }

    /// True when the running app bundle carries a runtime seed (a
    /// distribution/DMG build). False for a source-tree `swift run` where no
    /// seed was bundled — that case keeps the plain development fallback.
    static func isPackagedDistribution() -> Bool {
        guard let bundled = bundledNodeURL() else { return false }
        return FileManager.default.isExecutableFile(atPath: bundled.path)
    }

    /// The app bundle's runtime seed directory, only when it is present and
    /// runnable. This is seed input for RuntimeProvisioner only — nothing
    /// else should execute Node or scripts from here.
    static func seedRuntimeRoot() -> URL? {
        guard isPackagedDistribution() else { return nil }
        return Bundle.main.resourceURL?.appendingPathComponent("runtime")
    }

    static var installationLocationReady: Bool {
        guard isPackagedDistribution() else { return true }
        return isStableApplicationPath(Bundle.main.bundlePath)
    }

    static func isStableApplicationPath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return (standardized == "/Applications/Lynk.app" || standardized.hasPrefix("/Applications/"))
            && !standardized.contains("/AppTranslocation/")
            && !standardized.hasPrefix("/Volumes/")
    }

    static func runtimeRootBase() -> URL {
        if let override = ProcessInfo.processInfo.environment["ACP_GATEWAY_RUNTIME_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".acp-gateway", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
    }

    /// Pure parsing of ~/.acp-gateway/runtime/current.json. Defensively
    /// rejects a runtimeRoot under a ".app" bundle: runtime-installer.js
    /// only ever activates paths under the installed runtime root, never
    /// back inside the seed, so a ".app" path here means the pointer itself
    /// is corrupt/wrong and must not be trusted for execution.
    static func parseCurrentRuntime(data: Data) -> InstalledRuntimePointer? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (object["formatVersion"] as? Int) == 1 else { return nil }
        guard let rootPath = object["runtimeRoot"] as? String, !rootPath.isEmpty else { return nil }
        guard !rootPath.contains(".app") else { return nil }
        guard let gatewayVersion = object["gatewayVersion"] as? String, !gatewayVersion.isEmpty else { return nil }
        guard let gatewayBuildId = object["gatewayBuildId"] as? String, !gatewayBuildId.isEmpty else { return nil }
        return InstalledRuntimePointer(
            runtimeRoot: URL(fileURLWithPath: rootPath),
            gatewayVersion: gatewayVersion,
            gatewayBuildId: gatewayBuildId
        )
    }

    static func readCurrentRuntime() -> InstalledRuntimePointer? {
        let path = runtimeRootBase().appendingPathComponent("current.json")
        guard let data = try? Data(contentsOf: path), let pointer = parseCurrentRuntime(data: data) else { return nil }
        let node = pointer.runtimeRoot.appendingPathComponent("node/bin/node")
        let monitor = pointer.runtimeRoot.appendingPathComponent("src/monitor.js")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: monitor.path) else { return nil }
        return pointer
    }

    /// Resolves a resource (e.g. "src/monitor.js") from the installed
    /// runtime in a packaged build, or from the source-tree checkout during
    /// development. Never resolves it from the app bundle's seed.
    static func resourceURL(_ relativePath: String) throws -> URL {
        if isPackagedDistribution() {
            guard let installed = readCurrentRuntime() else { throw BundledRuntimeError.runtimeNotInstalled }
            let resolved = installed.runtimeRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                throw BundledRuntimeError.resourceNotFound(resolved.path)
            }
            return resolved
        }

        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { source.deleteLastPathComponent() }
        let development = source.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: development.path) else {
            throw BundledRuntimeError.resourceNotFound(development.path)
        }
        return development
    }

    static func validateVersion(at nodeURL: URL) throws {
        let process = Process()
        process.executableURL = nodeURL
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw BundledRuntimeError.nodeVersionCheckFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let major = parseMajorVersion(raw) else {
            throw BundledRuntimeError.nodeVersionCheckFailed(raw.isEmpty ? "empty output" : raw)
        }
        if major < minimumMajorVersion { throw BundledRuntimeError.nodeVersionTooOld(found: raw) }
    }

    /// Pure parsing helper: "v22.4.0" / "22.4.0" -> 22. Returns nil for anything unparseable.
    static func parseMajorVersion(_ raw: String) -> Int? {
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        guard let majorText = trimmed.split(separator: ".").first, !majorText.isEmpty else { return nil }
        return Int(majorText)
    }

    /// Builds the PATH used to launch bundled Node processes: the Node
    /// directory first, then the inherited PATH, then common local-tool
    /// locations so installer subprocesses (codex, claude, npm, uv, ...) resolve.
    static func launchPath(nodeDirectory: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            nodeDirectory.path,
            ProcessInfo.processInfo.environment["PATH"] ?? "",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin"
        ]
        .flatMap { $0.split(separator: ":").map(String.init) }
        .reduce(into: [String]()) { result, item in
            if !item.isEmpty && !result.contains(item) { result.append(item) }
        }
        .joined(separator: ":")
    }
}
