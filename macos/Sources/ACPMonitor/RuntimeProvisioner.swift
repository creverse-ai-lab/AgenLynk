import Foundation

// Copies the app bundle's runtime seed into ~/.acp-gateway/runtime once per
// distribution build, so every later Node/monitor/bootstrap execution runs
// from that installed copy — never the app bundle (see BundledRuntime).
// Spawns the *bundled* seed Node against app-runtime/runtime-installer-cli.js
// (reusing the Node module that owns the copy/verify/activate logic, rather
// than reimplementing it here) because no other Node exists yet on a fresh
// machine. A no-op when running from a source-tree checkout (no seed) or
// when the installed runtime already matches the bundled seed.
struct InstalledRuntimeInfo: Equatable {
    let runtimeRoot: String
    let gatewayVersion: String
    let gatewayBuildId: String
    let recoveryNotice: String?
}

enum RuntimeProvisionerError: LocalizedError {
    case processExited(Int32, String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case let .processExited(code, tail):
            let detail = tail.isEmpty ? "" : "\n\(tail)"
            return "Gateway runtime 설치에 실패했습니다 (exit \(code)).\(detail)"
        case let .invalidOutput(tail):
            let detail = tail.isEmpty ? "" : "\n\(tail)"
            return "Gateway runtime 설치 스크립트 출력을 해석하지 못했습니다.\(detail)"
        }
    }
}

final class RuntimeProvisioner {
    private var process: Process?

    /// Returns nil when there is no bundled seed to install (source-tree
    /// development). Throws an actionable error if a seed exists but fails
    /// to install/verify. The shared runner's watchdog bounds a hung seed
    /// Node — previously a first-install hang pinned startup forever.
    func ensureInstalled() async throws -> InstalledRuntimeInfo? {
        guard let seedRoot = BundledRuntime.seedRuntimeRoot() else { return nil }
        let result: SeedNodeProcess.Result
        do {
            result = try await SeedNodeProcess.run(
                seedRoot: seedRoot,
                script: "app-runtime/runtime-installer-cli.js",
                arguments: ["--seed", seedRoot.path],
                onSpawn: { [weak self] spawned in self?.process = spawned }
            )
            process = nil
        } catch let error as SeedNodeProcessError {
            process = nil
            throw RuntimeProvisionerError.invalidOutput(error.localizedDescription)
        }

        guard result.terminationStatus == 0 else {
            throw RuntimeProvisionerError.processExited(result.terminationStatus, result.stderrTail)
        }
        guard let info = Self.parse(result.stdoutText) else {
            throw RuntimeProvisionerError.invalidOutput(String(result.stdoutText.suffix(2_000)))
        }
        return info
    }

    func cancel() {
        process?.terminate()
    }

    /// Pure parsing of runtime-installer-cli.js's single-line JSON result.
    static func parse(_ output: String) -> InstalledRuntimeInfo? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimeRoot = object["runtimeRoot"] as? String, !runtimeRoot.isEmpty,
              let gatewayVersion = object["gatewayVersion"] as? String,
              let gatewayBuildId = object["gatewayBuildId"] as? String else { return nil }
        return InstalledRuntimeInfo(
            runtimeRoot: runtimeRoot,
            gatewayVersion: gatewayVersion,
            gatewayBuildId: gatewayBuildId,
            recoveryNotice: object["recoveryNotice"] as? String
        )
    }
}
