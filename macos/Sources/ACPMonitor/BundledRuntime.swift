import Foundation

// Locates and validates the Node runtime used to launch the Monitor sidecar
// and the installer/bootstrap script.
//
// Packaged builds (an app bundle carrying a runtime seed under
// Contents/Resources/gateway-seed/node/bin/node) must resolve Node and Gateway
// scripts from the *installed* runtime at ~/.acp-gateway/runtime — never the
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

    /// Same `monitor_*` stable-code vocabulary `MonitorClientError`/
    /// `MonitorDecodeError` use (see Models.swift): only the one case that
    /// means "the installed Gateway runtime is missing" maps to a code —
    /// the others are local Node-discovery failures with no server-side
    /// equivalent.
    var stableCode: String? {
        switch self {
        case .runtimeNotInstalled: "monitor_not_installed"
        case .nodeNotFound, .nodeVersionTooOld, .nodeVersionCheckFailed, .resourceNotFound: nil
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
        // so an explicit override or a PATH Node is the only option. A shipped
        // .app must not silently borrow a Homebrew Node the user may not have.
        guard !isApplicationBundle() else { throw BundledRuntimeError.runtimeNotInstalled }

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
        Bundle.main.resourceURL?.appendingPathComponent("gateway-seed/node/bin/node")
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
        return Bundle.main.resourceURL?.appendingPathComponent("gateway-seed")
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
        let gatewayClient = pointer.runtimeRoot.appendingPathComponent("gateway/gateway-client/index.js")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: gatewayClient.path) else { return nil }
        return pointer
    }

    /// Resolves a Gateway resource from the verified installed artifact.
    static func gatewayResourceURL(_ relativePath: String) throws -> URL {
        if isPackagedDistribution() {
            guard let installed = readCurrentRuntime() else { throw BundledRuntimeError.runtimeNotInstalled }
            let resolved = installed.runtimeRoot.appendingPathComponent("gateway").appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                throw BundledRuntimeError.resourceNotFound(resolved.path)
            }
            return resolved
        }

        // The source-tree fallback below is compiled with this machine's own
        // #filePath. Inside a distributed .app that path belongs to whoever
        // built it and cannot exist on the user's Mac, so a shipped app must
        // never take it — it would report a stranger's directory instead of
        // the real problem, which is that no runtime is installed.
        guard !isApplicationBundle() else { throw BundledRuntimeError.runtimeNotInstalled }

        for root in developmentGatewaySearchRoots() {
            let resolved = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: resolved.path) {
                return resolved
            }
        }
        throw BundledRuntimeError.resourceNotFound(relativePath)
    }

    /// Live source-tree lookup. Tests should call the explicit overload.
    static func developmentGatewaySearchRoots() -> [URL] {
        developmentGatewaySearchRoots(
            environmentRoot: ProcessInfo.processInfo.environment["ACP_LYNK_GATEWAY_DEVELOPMENT_ROOT"],
            installedGatewayRoot: readCurrentRuntime()?.runtimeRoot.appendingPathComponent("gateway"),
            fetchedGatewayRoot: developmentRepositoryRoot().appendingPathComponent("build/cache/gateway-runtime")
        )
    }

    /// Source-tree Gateway roots, in order:
    /// 1. `ACP_LYNK_GATEWAY_DEVELOPMENT_ROOT` (explicit checkout or unpacked artifact)
    /// 2. verified installed `runtime/current/gateway` when present
    /// 3. `build/cache/gateway-runtime` produced by `npm run gateway:fetch`
    /// There is no ambient sibling `../ACP` fallback.
    static func developmentGatewaySearchRoots(
        environmentRoot: String?,
        installedGatewayRoot: URL?,
        fetchedGatewayRoot: URL
    ) -> [URL] {
        var roots: [URL] = []
        if let environmentRoot, !environmentRoot.isEmpty {
            roots.append(URL(fileURLWithPath: environmentRoot))
        }
        if let installedGatewayRoot {
            roots.append(installedGatewayRoot)
        }
        roots.append(fetchedGatewayRoot)
        return roots
    }

    /// Stable symlink path used only while Gateway writes external MCP
    /// configuration. Normal app execution continues to use the verified
    /// current.json target above, so the symlink is not a second authority.
    static func stableGatewayResourceURL(_ relativePath: String) throws -> URL {
        guard isPackagedDistribution(), readCurrentRuntime() != nil else {
            return try gatewayResourceURL(relativePath)
        }
        let resolved = runtimeRootBase()
            .appendingPathComponent("current/gateway")
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw BundledRuntimeError.resourceNotFound(resolved.path)
        }
        return resolved
    }

    static func stableNodeURL() throws -> URL {
        guard isPackagedDistribution(), readCurrentRuntime() != nil else {
            return try locateNode()
        }
        let resolved = runtimeRootBase().appendingPathComponent("current/node/bin/node")
        guard FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw BundledRuntimeError.resourceNotFound(resolved.path)
        }
        return resolved
    }

    /// Resolves the app-owned sidecar. Packaged builds execute it directly
    /// from Contents/Resources/sidecar; it is never copied into a Gateway
    /// runtime version and therefore follows the app's 0.4.x version.
    static func sidecarResourceURL(_ relativePath: String) throws -> URL {
        let root: URL
        if isApplicationBundle() {
            guard let resources = Bundle.main.resourceURL else {
                throw BundledRuntimeError.resourceNotFound(relativePath)
            }
            root = resources.appendingPathComponent("sidecar")
        } else {
            root = developmentRepositoryRoot().appendingPathComponent("sidecar")
        }
        let resolved = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw BundledRuntimeError.resourceNotFound(resolved.path)
        }
        return resolved
    }

    private static func developmentRepositoryRoot() -> URL {
        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { source.deleteLastPathComponent() }
        return source
    }

    /// True when this process runs from a `.app`, i.e. anything a user
    /// installed rather than a `swift run` from a checkout.
    static func isApplicationBundle() -> Bool {
        Bundle.main.bundleURL.pathExtension == "app"
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
