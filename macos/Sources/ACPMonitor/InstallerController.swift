import Foundation

// Runs the bundled acp-gateway-bootstrap script once to perform first-run
// installation from the SwiftUI onboarding surface. Reuses the same
// installer/runInstaller behavior the CLI uses (no duplicated install logic):
// this only launches `node bootstrap.js --install-all --front-door <target>
// --refresh-registry` and interprets its bounded stdout/stderr.
struct BootstrapResult: Equatable {
    let ok: Bool
    let message: String
}

enum InstallerControllerError: LocalizedError {
    case processExited(Int32, String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case let .processExited(code, tail):
            let detail = tail.isEmpty ? "" : "\n\(tail)"
            return "설치 스크립트가 실패했습니다 (exit \(code)).\(detail)"
        case let .invalidOutput(tail):
            let detail = tail.isEmpty ? "" : "\n\(tail)"
            return "설치 스크립트 출력을 해석하지 못했습니다.\(detail)"
        }
    }
}

final class InstallerController {
    private static let maxOutputBytes = 256 * 1024
    private static let maxStderrTailLines = 20

    private var process: Process?

    func run(
        frontDoor: String,
        nodeOverride: String = "",
        onOutputLine: @escaping (String) -> Void
    ) async throws -> BootstrapResult {
        let nodeURL = try BundledRuntime.locateNode(override: nodeOverride)
        try BundledRuntime.validateVersion(at: nodeURL)
        let scriptURL = try BundledRuntime.resourceURL("src/bootstrap.js")

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = nodeURL
        process.arguments = [scriptURL.path, "--install-all", "--front-door", frontDoor, "--refresh-registry"]
        process.standardOutput = stdout
        process.standardError = stderr
        let nodeDirectory = nodeURL.deletingLastPathComponent()
        let npmPrefix = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global")
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "PATH": BundledRuntime.launchPath(nodeDirectory: nodeDirectory),
                "ACP_GATEWAY_NODE": nodeURL.path,
                "ACP_GATEWAY_RUNTIME_BIN": nodeDirectory.path,
                "NPM_CONFIG_PREFIX": npmPrefix.path
            ]
        ) { _, override in override }
        self.process = process

        try process.run()
        // readabilityHandler delivers chunks as they arrive with no
        // guarantee every callback has fired by the time the process exits,
        // so a final chunk could be dropped. Instead, loop availableData on
        // each pipe until EOF (mirrors SidecarController's ready-line read)
        // concurrently on both streams, and only inspect exit status once
        // both are fully drained.
        async let stdoutTask = Self.drain(stdout.fileHandleForReading, maxBytes: Self.maxOutputBytes)
        async let stderrTask = Self.drainLines(stderr.fileHandleForReading, maxLines: Self.maxStderrTailLines, onLine: onOutputLine)
        let (stdoutData, stderrTail) = await (stdoutTask, stderrTask)
        await Self.waitForExit(process)
        self.process = nil

        let exitCode = process.terminationStatus
        guard exitCode == 0 else {
            throw InstallerControllerError.processExited(exitCode, stderrTail.joined(separator: "\n"))
        }
        let outputText = String(data: stdoutData, encoding: .utf8) ?? ""
        guard let result = Self.parseResult(outputText) else {
            throw InstallerControllerError.invalidOutput(String(outputText.suffix(2_000)))
        }
        return result
    }

    func cancel() {
        process?.terminate()
    }

    private static func waitForExit(_ process: Process) async {
        guard process.isRunning else { return }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
    }

    private static func drain(_ handle: FileHandle, maxBytes: Int) async -> Data {
        await Task.detached {
            var data = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if data.count < maxBytes { data.append(chunk) }
            }
            return data
        }.value
    }

    private static func drainLines(_ handle: FileHandle, maxLines: Int, onLine: @escaping (String) -> Void) async -> [String] {
        await Task.detached {
            var tail: [String] = []
            var pending = Data()
            func record(_ line: String) {
                tail.append(line)
                if tail.count > maxLines { tail.removeFirst(tail.count - maxLines) }
                onLine(line)
            }
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    if let line = String(data: lineData, encoding: .utf8) { record(line) }
                }
            }
            if !pending.isEmpty, let line = String(data: pending, encoding: .utf8), !line.isEmpty {
                record(line)
            }
            return tail
        }.value
    }

    /// Pure parsing of acp-gateway-bootstrap's final JSON result line.
    static func parseResult(_ output: String) -> BootstrapResult? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else { return nil }
        let health = object["health"] as? [String: Any]
        let healthChecked = health?["checked"] as? Bool ?? false
        let healthOk = healthChecked ? (health?["ok"] as? Bool ?? false) : true
        let succeeded = ok && healthOk
        let message = succeeded
            ? "설치가 완료되었습니다."
            : "설치는 완료되었지만 Gateway 상태 확인에 실패했습니다."
        return BootstrapResult(ok: succeeded, message: message)
    }
}
