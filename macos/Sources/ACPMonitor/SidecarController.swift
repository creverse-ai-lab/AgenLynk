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
}

final class SidecarController {
    private var process: Process?
    private var outputPipe: Pipe?
    private var readyTask: Task<MonitorEndpoint, Error>?
    private var generation = 0

    func start(nodeOverride: String = "", localWatcherProjectPath: String = "") async throws -> MonitorEndpoint {
        stop()
        generation += 1
        let startGeneration = generation
        let nodeURL = try BundledRuntime.locateNode(override: nodeOverride)
        try BundledRuntime.validateVersion(at: nodeURL)
        let scriptURL = try BundledRuntime.resourceURL("src/monitor.js")
        let process = Process()
        let output = Pipe()

        process.executableURL = nodeURL
        process.arguments = [scriptURL.path]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        let path = BundledRuntime.launchPath(nodeDirectory: nodeURL.deletingLastPathComponent())
        var monitorEnvironment = [
            "ACP_GATEWAY_MONITOR_PORT": "0",
            "ACP_GATEWAY_MONITOR_AUTOSTART": "1",
            "ACP_GATEWAY_MONITOR_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
            "PATH": path,
            "ACP_GATEWAY_NODE": nodeURL.path,
            "ACP_GATEWAY_RUNTIME_BIN": nodeURL.deletingLastPathComponent().path,
            "NPM_CONFIG_PREFIX": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".npm-global").path
        ]
        let watcherScript = URL(fileURLWithPath: localWatcherProjectPath, isDirectory: true)
            .appendingPathComponent("codex_app_watcher.py")
        if FileManager.default.fileExists(atPath: watcherScript.path) {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            monitorEnvironment["ACP_MONITOR_LOCAL_WATCHER_SCRIPT"] = watcherScript.path
            monitorEnvironment["ACP_MONITOR_LOCAL_STATE"] = applicationSupport
                .appendingPathComponent("ACPMonitor/local-agent-state.json").path
        }
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
                    return MonitorEndpoint(baseURL: url, apiToken: apiToken)
                }
            }
            if process.isRunning { throw SidecarError.invalidReadyMessage }
            if process.terminationStatus != 0 { throw SidecarError.processExited(process.terminationStatus) }
            throw SidecarError.invalidReadyMessage
        }
        self.readyTask = readyTask
        do {
            let endpoint = try await readyTask.value
            if generation == startGeneration { self.readyTask = nil }
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
