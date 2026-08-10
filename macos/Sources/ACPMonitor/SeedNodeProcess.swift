import Foundation

enum SeedNodeProcessError: LocalizedError {
    case seedIncomplete(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .seedIncomplete(path):
            "번들 runtime seed가 완전하지 않습니다: \(path)"
        case .timedOut:
            "seed 실행이 응답하지 않아 중단했습니다. 다시 시도해 주세요."
        }
    }
}

/// One shared way to run a CLI from the app's bundled runtime seed with the
/// seed's own Node.
///
/// The provisioner and the updater each grew their own copy of this pattern
/// (resolve node/script, wire pipes, drain both to EOF concurrently, wait for
/// exit) — and the copies had already diverged: the updater had a watchdog
/// against a hung seed Node while the provisioner did not, so the identical
/// hang on FIRST INSTALL pinned startup forever. Pipe draining is exactly the
/// kind of code that must not exist twice: drain before waitUntilExit or a
/// full pipe deadlocks the child.
enum SeedNodeProcess {
    struct Result {
        let terminationStatus: Int32
        let stdout: Data
        let stderr: Data

        var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrTail: String { String((String(data: stderr, encoding: .utf8) ?? "").suffix(2_000)) }
    }

    /// Runs `<seedRoot>/node/bin/node <seedRoot>/<script> <arguments>` and
    /// returns both streams with the exit status. `timeout` terminates a hung
    /// child so no caller's busy/progress state can be pinned forever.
    static func run(
        seedRoot: URL,
        script: String,
        arguments: [String],
        timeout: TimeInterval = 300,
        onSpawn: (Process) -> Void = { _ in }
    ) async throws -> Result {
        let nodeURL = seedRoot.appendingPathComponent("node/bin/node")
        let scriptURL = seedRoot.appendingPathComponent(script)
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw SeedNodeProcessError.seedIncomplete(seedRoot.path)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = nodeURL
        process.arguments = [scriptURL.path] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Lets a caller keep a termination handle (app shutdown cancels an
        // in-flight install) without owning the pipe/wait plumbing.
        onSpawn(process)

        let timedOut = LockedFlag()
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        defer { watchdog.cancel() }

        // Drain both pipes to EOF concurrently BEFORE inspecting exit status,
        // so a full final chunk on either stream is never missed — and so a
        // chatty child can never fill a pipe and deadlock against our wait.
        async let stdoutData = readToEnd(stdout.fileHandleForReading)
        async let stderrData = readToEnd(stderr.fileHandleForReading)
        let (outData, errData) = await (stdoutData, stderrData)
        await waitForExit(process)
        if timedOut.isSet { throw SeedNodeProcessError.timedOut }

        return Result(terminationStatus: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// A bool the watchdog task and the awaiting caller can share safely.
    final class LockedFlag: @unchecked Sendable {
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
        await Task.detached { handle.readDataToEndOfFile() }.value
    }

    private static func waitForExit(_ process: Process) async {
        guard process.isRunning else { return }
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
    }
}
