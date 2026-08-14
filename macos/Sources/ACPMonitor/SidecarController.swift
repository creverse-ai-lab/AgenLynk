import Darwin
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

    var stableCode: String? {
        switch self {
        case .invalidReadyMessage: "monitor_api_incompatible"
        case .processExited: nil
        }
    }
}

struct SidecarProcessStopResult: Equatable, Sendable {
    let forceTerminationUsed: Bool
    let stopped: Bool
}

/// Shared bounded shutdown policy. The async probes make the policy directly
/// testable with a fake process while production keeps `Process` actor-isolated.
enum BoundedProcessTermination {
    static func stop(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 25_000_000,
        isRunning: @escaping @Sendable () async -> Bool,
        terminate: @escaping @Sendable () async -> Void,
        forceTerminate: @escaping @Sendable () async -> Void
    ) async -> SidecarProcessStopResult {
        guard await isRunning() else {
            return SidecarProcessStopResult(forceTerminationUsed: false, stopped: true)
        }
        await terminate()
        if await waitUntilStopped(
            timeoutNanoseconds: timeoutNanoseconds,
            pollNanoseconds: pollNanoseconds,
            isRunning: isRunning
        ) {
            return SidecarProcessStopResult(forceTerminationUsed: false, stopped: true)
        }
        await forceTerminate()
        let stopped = await waitUntilStopped(
            timeoutNanoseconds: timeoutNanoseconds,
            pollNanoseconds: pollNanoseconds,
            isRunning: isRunning
        )
        return SidecarProcessStopResult(forceTerminationUsed: true, stopped: stopped)
    }

    private static func waitUntilStopped(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64,
        isRunning: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        while await isRunning() {
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            if elapsed >= timeoutNanoseconds { return false }
            try? await Task.sleep(nanoseconds: min(pollNanoseconds, timeoutNanoseconds - elapsed))
        }
        return true
    }
}

/// Owns the sidecar `Process`, pipes, readiness task, and shutdown lifecycle.
/// No `Process` operation runs on MainActor and shutdown never calls the
/// blocking `waitUntilExit()` API.
actor SidecarProcessActor {
    struct LaunchResult: Sendable {
        let endpoint: MonitorEndpoint
        let meta: MonitorMeta
    }

    private var process: Process?
    private var outputPipe: Pipe?
    private var readyTask: Task<LaunchResult, Error>?
    private var generation = 0

    private struct ProcessResources {
        let process: Process?
        let outputPipe: Pipe?
        let readyTask: Task<LaunchResult, Error>?
    }

    func isRunning() -> Bool {
        process?.isRunning == true
    }

    func start(nodeOverride: String = "") async throws -> LaunchResult {
        generation += 1
        let startGeneration = generation
        let previous = detachCurrentProcess()
        await stop(resources: previous)
        guard generation == startGeneration, !Task.isCancelled else { throw CancellationError() }
        let nodeURL = try BundledRuntime.locateNode(override: nodeOverride)
        try BundledRuntime.validateVersion(at: nodeURL)
        let scriptURL = try BundledRuntime.sidecarResourceURL("src/server/monitor.js")
        let gatewayClientURL = try BundledRuntime.gatewayResourceURL("gateway-client/index.js")
        let gatewayRuntimeRoot = gatewayClientURL.deletingLastPathComponent().deletingLastPathComponent()
        let launched = Process()
        let output = Pipe()

        launched.executableURL = nodeURL
        launched.arguments = ["--disable-warning=ExperimentalWarning", scriptURL.path]
        launched.standardOutput = output
        launched.standardError = FileHandle.standardError
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
        launched.environment = ProcessInfo.processInfo.environment.merging(monitorEnvironment) { _, appValue in appValue }

        try launched.run()
        process = launched
        outputPipe = output
        let task = Task.detached(priority: .userInitiated) {
            var pending = Data()
            while true {
                try Task.checkCancellation()
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
                    let object = JSONValue(any: value).objectValue ?? [:]
                    try MonitorCompatibility.validate(object)
                    return LaunchResult(
                        endpoint: MonitorEndpoint(baseURL: url, apiToken: apiToken),
                        meta: MonitorMeta(object)
                    )
                }
            }
            throw SidecarError.invalidReadyMessage
        }
        readyTask = task
        do {
            let result = try await task.value
            guard generation == startGeneration,
                  !Task.isCancelled,
                  process === launched else { throw CancellationError() }
            readyTask = nil
            return result
        } catch {
            let reportedError: Error
            if error is CancellationError {
                reportedError = error
            } else if !launched.isRunning, launched.terminationStatus != 0 {
                reportedError = SidecarError.processExited(launched.terminationStatus)
            } else {
                reportedError = error
            }
            if generation == startGeneration {
                let failed = detachCurrentProcess(matching: launched)
                await stop(resources: failed)
            }
            throw reportedError
        }
    }

    @discardableResult
    func stop(timeoutNanoseconds: UInt64 = 750_000_000) async -> SidecarProcessStopResult {
        generation += 1
        let resources = detachCurrentProcess()
        return await stop(resources: resources, timeoutNanoseconds: timeoutNanoseconds)
    }

    private func detachCurrentProcess(matching expected: Process? = nil) -> ProcessResources {
        if let expected, process !== expected {
            return ProcessResources(process: nil, outputPipe: nil, readyTask: nil)
        }
        let resources = ProcessResources(process: process, outputPipe: outputPipe, readyTask: readyTask)
        process = nil
        outputPipe = nil
        readyTask = nil
        return resources
    }

    @discardableResult
    private func stop(
        resources: ProcessResources,
        timeoutNanoseconds: UInt64 = 750_000_000
    ) async -> SidecarProcessStopResult {
        resources.readyTask?.cancel()
        guard let stopping = resources.process else {
            close(resources.outputPipe)
            return SidecarProcessStopResult(forceTerminationUsed: false, stopped: true)
        }
        guard stopping.isRunning else {
            close(resources.outputPipe)
            return SidecarProcessStopResult(forceTerminationUsed: false, stopped: true)
        }
        let pid = stopping.processIdentifier
        stopping.terminate()
        if await waitUntilStopped(stopping, timeoutNanoseconds: timeoutNanoseconds) {
            close(resources.outputPipe)
            return SidecarProcessStopResult(forceTerminationUsed: false, stopped: true)
        }
        if stopping.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        let stopped = await waitUntilStopped(stopping, timeoutNanoseconds: timeoutNanoseconds)
        close(resources.outputPipe)
        return SidecarProcessStopResult(forceTerminationUsed: true, stopped: stopped)
    }

    private func waitUntilStopped(_ process: Process, timeoutNanoseconds: UInt64) async -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        while process.isRunning {
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            if elapsed >= timeoutNanoseconds { return false }
            try? await Task.sleep(nanoseconds: min(25_000_000, timeoutNanoseconds - elapsed))
        }
        return true
    }

    private func close(_ pipe: Pipe?) {
        pipe?.fileHandleForReading.closeFile()
    }
}

/// MainActor-facing facade. It retains only value-type handshake metadata;
/// process ownership remains inside `SidecarProcessActor`.
@MainActor
final class SidecarController {
    private let processActor: SidecarProcessActor
    private(set) var meta: MonitorMeta?

    init(processActor: SidecarProcessActor = SidecarProcessActor()) {
        self.processActor = processActor
    }

    func start(nodeOverride: String = "") async throws -> MonitorEndpoint {
        let result = try await processActor.start(nodeOverride: nodeOverride)
        meta = result.meta
        return result.endpoint
    }

    func stop() async {
        meta = nil
        await processActor.stop()
    }

    func isRunning() async -> Bool {
        await processActor.isRunning()
    }
}
