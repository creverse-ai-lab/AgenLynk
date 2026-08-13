import Foundation

enum SidecarError: LocalizedError {
    case processExited(Int32)
    case invalidReadyMessage

    var errorDescription: String? {
        switch self {
        case let .processExited(code):
            "Monitor sidecar가 준비되기 전에 종료되었습니다 (exit \(code))."
        case .invalidReadyMessage:
            "Monitor sidecar가 올바른 준비 메시지를 보내지 않았습니다."
        }
    }

    /// Same `monitor_*` stable-code vocabulary as `MonitorDecodeError`/
    /// `MonitorClientError` (see Models.swift). A handshake line that never
    /// parsed into a well-formed `monitor_ready` message is the same
    /// malformed/missing-contract situation as a decode failure; an exit
    /// with no ready message at all carries no version information to
    /// classify, so it stays uncoded.
    var stableCode: String? {
        switch self {
        case .invalidReadyMessage: "monitor_api_incompatible"
        case .processExited: nil
        }
    }
}

final class SidecarController {
    private var process: Process?
    private var outputPipe: Pipe?
    private var readyTask: Task<(MonitorEndpoint, MonitorMeta), Error>?
    private var generation = 0

    /// Version/compatibility metadata parsed from the last accepted
    /// `monitor_ready` message. Never carries the `apiToken`.
    private(set) var meta: MonitorMeta?

    func start(nodeOverride: String = "") async throws -> MonitorEndpoint {
        stop()
        generation += 1
        let startGeneration = generation
        let nodeURL = try BundledRuntime.locateNode(override: nodeOverride)
        try BundledRuntime.validateVersion(at: nodeURL)
        let scriptURL = try BundledRuntime.sidecarResourceURL("src/server/monitor.js")
        let gatewayClientURL = try BundledRuntime.gatewayResourceURL("gateway-client/index.js")
        let gatewayRuntimeRoot = gatewayClientURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()

        process.executableURL = nodeURL
        // The monitor reads Codex's SQLite database through node:sqlite, which
        // is still flagged experimental in Node 22. Silence that one warning
        // rather than every warning, so real ones still reach the log.
        process.arguments = ["--disable-warning=ExperimentalWarning", scriptURL.path]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        let path = BundledRuntime.launchPath(nodeDirectory: nodeURL.deletingLastPathComponent())
        let monitorEnvironment = [
            "ACP_GATEWAY_MONITOR_PORT": "0",
            "ACP_GATEWAY_MONITOR_AUTOSTART": "1",
            "ACP_GATEWAY_MONITOR_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
            "PATH": path,
            "ACP_GATEWAY_NODE": nodeURL.path,
            "ACP_GATEWAY_RUNTIME_BIN": nodeURL.deletingLastPathComponent().path,
            "ACP_GATEWAY_CLIENT_ENTRYPOINT": gatewayClientURL.path,
            "ACP_GATEWAY_ACTIVE_ROOT": gatewayRuntimeRoot.path,
            "NPM_CONFIG_PREFIX": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".npm-global").path
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(monitorEnvironment) { _, appValue in appValue }

        try process.run()
        self.process = process
        outputPipe = output

        let readyTask = Task.detached(priority: .userInitiated) {
            var pending = Data()
            while process.isRunning || !pending.isEmpty {
                try Task.checkCancellation()
                // read(upToCount:) can wait for the full requested length on a
                // pipe while the long-lived sidecar keeps stdout open. Read the
                // bytes currently available so the short monitor_ready line is
                // delivered immediately.
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          value["kind"] as? String == "monitor_ready",
                          let rawURL = value["url"] as? String,
                          let url = URL(string: rawURL),
                          let apiToken = value["apiToken"] as? String else { continue }
                    // Reject an unsupported schema/API major up front instead of
                    // handing back an endpoint the rest of the app can't safely
                    // talk to; do not partially decode an incompatible message.
                    let object = JSONValue(any: value).objectValue ?? [:]
                    try MonitorCompatibility.validate(object)
                    return (MonitorEndpoint(baseURL: url, apiToken: apiToken), MonitorMeta(object))
                }
            }
            if process.isRunning { throw SidecarError.invalidReadyMessage }
            if process.terminationStatus != 0 { throw SidecarError.processExited(process.terminationStatus) }
            throw SidecarError.invalidReadyMessage
        }
        self.readyTask = readyTask
        do {
            let (endpoint, meta) = try await readyTask.value
            if generation == startGeneration {
                self.readyTask = nil
                self.meta = meta
            }
            return endpoint
        } catch {
            if generation == startGeneration {
                self.readyTask = nil
                stop()
            }
            throw error
        }
    }

    func stop() {
        generation += 1
        readyTask?.cancel()
        readyTask = nil
        meta = nil
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
        outputPipe?.fileHandleForReading.closeFile()
        outputPipe = nil
    }

    deinit { stop() }
}
