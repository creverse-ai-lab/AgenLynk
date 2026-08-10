import Foundation

// Copies the app bundle's runtime seed into ~/.acp-gateway/runtime once per
// distribution build, so every later Node/monitor/bootstrap execution runs
// from that installed copy — never the app bundle (see BundledRuntime).
// Spawns the *bundled* seed Node against the bundled src/runtime-installer-cli.js
// (reusing the Node module that owns the copy/verify/activate logic, rather
// than reimplementing it here) because no other Node exists yet on a fresh
// machine. A no-op when running from a source-tree checkout (no seed) or
// when the installed runtime already matches the bundled seed.
struct InstalledRuntimeInfo: Equatable {
    let runtimeRoot: String
    let gatewayVersion: String
    let gatewayBuildId: String
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
    /// to install/verify.
    func ensureInstalled() async throws -> InstalledRuntimeInfo? {
        guard let seedRoot = BundledRuntime.seedRuntimeRoot() else { return nil }
        let nodeURL = seedRoot.appendingPathComponent("node/bin/node")
        let scriptURL = seedRoot.appendingPathComponent("src/runtime-installer-cli.js")
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw RuntimeProvisionerError.invalidOutput("bundled runtime seed is incomplete: \(seedRoot.path)")
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = nodeURL
        process.arguments = [scriptURL.path, "--seed", seedRoot.path]
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process

        try process.run()
        // Drain both pipes to EOF concurrently before inspecting exit status
        // so a full final chunk on either stream is never missed/raced.
        async let stdoutData = Self.readToEndOfFile(stdout.fileHandleForReading)
        async let stderrData = Self.readToEndOfFile(stderr.fileHandleForReading)
        let (outData, errData) = await (stdoutData, stderrData)
        await Self.waitForExit(process)
        self.process = nil

        guard process.terminationStatus == 0 else {
            let tail = String(data: errData, encoding: .utf8) ?? ""
            throw RuntimeProvisionerError.processExited(process.terminationStatus, String(tail.suffix(2_000)))
        }
        let outputText = String(data: outData, encoding: .utf8) ?? ""
        guard let info = Self.parse(outputText) else {
            throw RuntimeProvisionerError.invalidOutput(String(outputText.suffix(2_000)))
        }
        return info
    }

    func cancel() {
        process?.terminate()
    }

    private static func readToEndOfFile(_ handle: FileHandle) async -> Data {
        await Task.detached { handle.readDataToEndOfFile() }.value
    }

    private static func waitForExit(_ process: Process) async {
        guard process.isRunning else { return }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
    }

    /// Pure parsing of runtime-installer-cli.js's single-line JSON result.
    static func parse(_ output: String) -> InstalledRuntimeInfo? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimeRoot = object["runtimeRoot"] as? String, !runtimeRoot.isEmpty,
              let gatewayVersion = object["gatewayVersion"] as? String,
              let gatewayBuildId = object["gatewayBuildId"] as? String else { return nil }
        return InstalledRuntimeInfo(runtimeRoot: runtimeRoot, gatewayVersion: gatewayVersion, gatewayBuildId: gatewayBuildId)
    }
}
