import Foundation

enum SidecarError: LocalizedError {
    case nodeNotFound
    case monitorScriptNotFound(String)
    case processExited(Int32)
    case invalidReadyMessage

    var errorDescription: String? {
        switch self {
        case .nodeNotFound:
            "Node 22 이상을 찾지 못했습니다. Settings에서 Node 실행 파일 경로를 지정하세요."
        case let .monitorScriptNotFound(path):
            "Monitor sidecar를 찾지 못했습니다: \(path)"
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

    func start(nodeOverride: String = "") async throws -> MonitorEndpoint {
        stop()
        let nodeURL = try locateNode(override: nodeOverride)
        let scriptURL = try locateMonitorScript()
        let process = Process()
        let output = Pipe()

        process.executableURL = nodeURL
        process.arguments = [scriptURL.path]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ACP_GATEWAY_MONITOR_PORT": "0",
            "ACP_GATEWAY_MONITOR_AUTOSTART": "1",
            "ACP_GATEWAY_MONITOR_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier)
        ]) { _, appValue in appValue }

        try process.run()
        self.process = process
        outputPipe = output

        return try await Task.detached(priority: .userInitiated) {
            var pending = Data()
            while process.isRunning || !pending.isEmpty {
                // read(upToCount:) can wait for the full requested length on a
                // pipe while the long-lived sidecar keeps stdout open. Read the
                // bytes currently available so the short monitor_ready line is
                // delivered immediately.
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty {
                    if !process.isRunning { break }
                    continue
                }
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
            if process.terminationStatus != 0 { throw SidecarError.processExited(process.terminationStatus) }
            throw SidecarError.invalidReadyMessage
        }.value
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil
        outputPipe?.fileHandleForReading.closeFile()
        outputPipe = nil
    }

    private func locateNode(override: String) throws -> URL {
        let environmentOverride = ProcessInfo.processInfo.environment["ACP_GATEWAY_NODE"] ?? ""
        let candidates = [override, environmentOverride, "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .filter { !$0.isEmpty }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SidecarError.nodeNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private func locateMonitorScript() throws -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("runtime/src/monitor.js")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { source.deleteLastPathComponent() }
        let development = source.appendingPathComponent("src/monitor.js")
        guard FileManager.default.fileExists(atPath: development.path) else {
            throw SidecarError.monitorScriptNotFound(development.path)
        }
        return development
    }

    deinit { stop() }
}
