import Foundation
import Darwin

enum PetControllerError: LocalizedError {
    case executablePathRequired
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
        case .executablePathRequired:
            "Pet 실행 파일 경로를 먼저 선택하세요."
        case let .executableNotFound(path):
            "Pet 실행 파일을 찾지 못했습니다: \(path)"
        }
    }
}

/// Launches and feeds a user-selected Pet/user-renderer executable. The
/// renderer is output-only: it is given an explicit executable path (no
/// project-directory or `.build` assumptions), a benign environment
/// allowlist, and read-only `pet-state.json`/`pet-actions.json` contract
/// files — never a mutation/control channel back into the Gateway.
@MainActor
final class PetController {
    private let fileManager: FileManager
    private let stateDirectory: URL
    private(set) var process: Process?
    private var logHandle: FileHandle?
    /// Monotonic for the app process's lifetime; never reset by start/stop.
    private var sequence = 0
    /// Every contract write goes through this one serial queue, so a
    /// background update can never land after (and roll back) a newer one.
    private let writeQueue = DispatchQueue(label: "agenlynk.pet.contract-writes", qos: .utility)
    /// `pet.log` is rotated to `pet.log.1` at start once it passes this.
    static let logRotationBytes = 5 * 1_024 * 1_024

    /// `stateDirectory` is injectable so boundary tests can observe the real
    /// files and the real child process without touching Application Support.
    init(fileManager: FileManager = .default, stateDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let stateDirectory {
            self.stateDirectory = stateDirectory
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.stateDirectory = applicationSupport.appendingPathComponent("ACPMonitor", isDirectory: true)
        }
    }

    var isRunning: Bool { process?.isRunning == true }
    var stateFileURL: URL { stateDirectory.appendingPathComponent("pet-state.json") }
    var actionsFileURL: URL { stateDirectory.appendingPathComponent("pet-actions.json") }

    func start(
        executablePath: String,
        projection: PetActivityProjection,
        style: PetStyle = .orbit,
        onTermination: @escaping @MainActor (Int32) -> Void
    ) throws {
        stop()
        let trimmedPath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw PetControllerError.executablePathRequired
        }
        let executableURL = URL(fileURLWithPath: trimmedPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw PetControllerError.executableNotFound(executableURL.path)
        }

        try write(projection)
        let logURL = stateDirectory.appendingPathComponent("pet.log")
        Self.rotateLogIfNeeded(logURL, fileManager: fileManager)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.environment = PetChildEnvironment.make(
            from: ProcessInfo.processInfo.environment,
            stateFilePath: stateFileURL.path,
            actionsFilePath: actionsFileURL.path,
            style: style.rawValue
        )
        process.terminationHandler = { [weak self] finished in
            guard let controller = self else { return }
            Task { @MainActor in
                guard controller.process === finished else { return }
                controller.process = nil
                try? controller.logHandle?.close()
                controller.logHandle = nil
                onTermination(finished.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw error
        }
        self.logHandle = logHandle
        self.process = process
    }

    func update(_ projection: PetActivityProjection) throws {
        try write(projection)
    }

    /// `update` without blocking the main actor: the envelopes are encoded
    /// and written on the serial write queue; `completion` reports the
    /// outcome back on the main actor (nil on success).
    func scheduleUpdate(_ projection: PetActivityProjection, completion: @escaping @MainActor (Error?) -> Void) {
        let job = nextWriteJob(projection)
        writeQueue.async {
            let failure: Error?
            do {
                try job.run()
                failure = nil
            } catch {
                failure = error
            }
            Task { @MainActor in completion(failure) }
        }
    }

    /// Waits until every scheduled write has landed (tests, shutdown).
    func waitForPendingWrites() {
        writeQueue.sync {}
    }

    /// Keeps the renderer's log bounded: past `logRotationBytes` the current
    /// log becomes `pet.log.1` (replacing an older backup) and a new one starts.
    static func rotateLogIfNeeded(_ logURL: URL, fileManager: FileManager = .default) {
        guard let size = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue,
              size > logRotationBytes else { return }
        let backup = logURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: backup)
        if (try? fileManager.moveItem(at: logURL, to: backup)) == nil {
            // Could not move it aside: start over rather than grow forever.
            try? fileManager.removeItem(at: logURL)
        }
    }

    func stop() {
        guard let process else {
            try? logHandle?.close()
            logHandle = nil
            return
        }
        self.process = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            // Never block the main actor on an uncooperative overlay. A normal
            // AppKit process exits immediately; force only this owned child if
            // it is still alive after the grace period.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        try? logHandle?.close()
        logHandle = nil
    }

    /// Both files are derived from one projection/update so they always
    /// describe the same moment, and share the same monotonic sequence.
    /// Synchronous, but still through the write queue to keep the order.
    private func write(_ projection: PetActivityProjection) throws {
        let job = nextWriteJob(projection)
        var failure: Error?
        writeQueue.sync {
            do { try job.run() } catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// Claims the next sequence number on the main actor; the job itself
    /// touches no actor state.
    private func nextWriteJob(_ projection: PetActivityProjection) -> PetContractWrite {
        sequence += 1
        return PetContractWrite(
            projection: projection,
            sequence: sequence,
            generatedAt: Date(),
            directory: stateDirectory,
            stateFileURL: stateFileURL,
            actionsFileURL: actionsFileURL
        )
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
    }
}

/// One update of the two contract files, runnable on any thread.
private struct PetContractWrite: Sendable {
    let projection: PetActivityProjection
    let sequence: Int
    let generatedAt: Date
    let directory: URL
    let stateFileURL: URL
    let actionsFileURL: URL

    func run() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try write(PetStateEnvelope.make(projection: projection, sequence: sequence, generatedAt: generatedAt), to: stateFileURL)
        try write(PetActionsEnvelope.make(projection: projection, sequence: sequence, generatedAt: generatedAt), to: actionsFileURL)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
