import Foundation

enum RuntimeUpdaterError: LocalizedError {
    case seedUnavailable
    case processExited(Int32, String)
    case invalidOutput(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .seedUnavailable:
            "이 빌드에는 실행할 Gateway runtime seed가 없습니다."
        case let .processExited(code, detail):
            "runtime updater가 종료되었습니다 (exit \(code)). \(detail)"
        case let .invalidOutput(detail):
            "runtime updater 응답을 해석하지 못했습니다: \(detail)"
        case .timedOut:
            "runtime updater가 응답하지 않아 중단했습니다. 다시 시도해 주세요."
        }
    }
}

/// Runs `runtime-updater-cli.js` from the app's **own bundled seed**, using the
/// seed's Node — the same pattern `RuntimeProvisioner` uses for first install.
///
/// Going through the monitor's HTTP API instead would not work for the case
/// this feature exists for: an existing install whose runtime predates the
/// updater endpoints has a monitor that cannot serve them, so the app could
/// never replace it. The app bundle always carries a current updater, so the
/// seed is the only source that is guaranteed new enough to update from.
///
/// The daemon and monitor still run from the *installed* runtime; only this
/// one-shot operation runs from the seed.
final class RuntimeUpdaterController {
    private let seedRoot: URL?

    init(seedRoot: URL? = BundledRuntime.seedRuntimeRoot()) {
        self.seedRoot = seedRoot
    }

    var isAvailable: Bool { seedRoot != nil }

    /// `blockers` is passed through to the updater, which refuses to activate
    /// or roll back while any are present.
    func run(_ operation: String, arguments: [String] = [], blockers: [String] = []) async throws -> JSONValue {
        guard let seedRoot else { throw RuntimeUpdaterError.seedUnavailable }
        let nodeURL = seedRoot.appendingPathComponent("node/bin/node")
        let scriptURL = seedRoot.appendingPathComponent("src/runtime-updater-cli.js")
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw RuntimeUpdaterError.seedUnavailable
        }

        var argv = [scriptURL.path, operation] + arguments
        if !blockers.isEmpty {
            argv += ["--blockers", String(decoding: try JSONEncoder().encode(blockers), as: UTF8.self)]
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = nodeURL
        process.arguments = argv
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Watchdog: a hung seed Node (bad seed, FS stall) would otherwise pin
        // runtimeBusy forever and leave the Settings tab bricked — run() would
        // never return, so no defer ever resets the state. Stage copies a full
        // runtime tree, so the ceiling is generous.
        let timedOut = LockedFlag()
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        defer { watchdog.cancel() }

        async let outData = Self.readToEnd(stdout.fileHandleForReading)
        async let errData = Self.readToEnd(stderr.fileHandleForReading)
        let (out, err) = await (outData, errData)
        await Self.waitForExit(process)
        if timedOut.isSet { throw RuntimeUpdaterError.timedOut }

        // The CLI prints exactly one JSON envelope for success and for expected
        // failure alike, and only sets a nonzero exit code alongside it — so a
        // parseable envelope is authoritative even when the exit code is 1.
        let text = String(data: out, encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let value = JSONValue(any: parsed).objectValue else {
            let tail = String(data: err, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw RuntimeUpdaterError.processExited(process.terminationStatus, String(tail.suffix(2_000)))
            }
            throw RuntimeUpdaterError.invalidOutput(String(text.suffix(500)))
        }
        return .object(value)
    }

    /// A bool the watchdog task and the awaiting caller can share safely.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
