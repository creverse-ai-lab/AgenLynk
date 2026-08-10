import Foundation

// Pure parsing of ~/.acp-gateway/install.json used to decide whether the app
// can go straight to the dashboard or must show first-run onboarding. This
// mirrors the subset of src/installer.js's readInstallState invariants that
// matter for "is there a usable existing installation" (version, Control
// identity token/rootId) without depending on Node or the installer module.
enum InstallStateChecker {
    static func isValid(data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard (object["version"] as? Int) == 1 else { return false }
        guard let identity = object["identity"] as? [String: Any] else { return false }
        guard let token = identity["token"] as? String, token.count >= 24 else { return false }
        guard let rootId = identity["rootId"] as? String, !rootId.isEmpty else { return false }
        return true
    }

    static func isValid(at path: URL) -> Bool {
        guard let data = try? Data(contentsOf: path) else { return false }
        return isValid(data: data)
    }

    static func defaultPath() -> URL {
        if let override = ProcessInfo.processInfo.environment["ACP_GATEWAY_INSTALL_STATE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".acp-gateway", isDirectory: true)
            .appendingPathComponent("install.json")
    }
}
