import Foundation
import Darwin

enum PetControllerError: LocalizedError {
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        stateDirectory = applicationSupport.appendingPathComponent("ACPMonitor", isDirectory: true)
    }

    var isRunning: Bool { process?.isRunning == true }
    var stateFileURL: URL { stateDirectory.appendingPathComponent("pet-state.json") }
    var actionsFileURL: URL { stateDirectory.appendingPathComponent("pet-actions.json") }

    func start(
        executablePath: String,
        projection: PetActivityProjection,
        onTermination: @escaping @MainActor (Int32) -> Void
    ) throws {
        stop()
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw PetControllerError.executableNotFound(executableURL.path)
        }

        try write(projection)
        let logURL = stateDirectory.appendingPathComponent("pet.log")
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
            actionsFilePath: actionsFileURL.path
        )
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.process = nil
                try? self.logHandle?.close()
                self.logHandle = nil
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
    private func write(_ projection: PetActivityProjection) throws {
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        sequence += 1
        let generatedAt = Date()
        try writeAtomically(PetStateEnvelope.make(projection: projection, sequence: sequence, generatedAt: generatedAt), to: stateFileURL)
        try writeAtomically(PetActionsEnvelope.make(projection: projection, sequence: sequence, generatedAt: generatedAt), to: actionsFileURL)
    }

    private func writeAtomically(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
    }
}
