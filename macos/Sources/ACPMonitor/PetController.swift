import Foundation
import Darwin

enum PetControllerError: LocalizedError {
    case projectDirectoryNotFound(String)
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .projectDirectoryNotFound(path):
            "Pet 프로젝트 경로를 찾지 못했습니다: \(path)"
        case let .executableNotFound(path):
            "Pet 실행 파일을 찾지 못했습니다: \(path) (pet-ctl.sh build를 먼저 실행하세요.)"
        }
    }
}

@MainActor
final class PetController {
    private let fileManager: FileManager
    private let stateDirectory: URL
    private(set) var process: Process?
    private var logHandle: FileHandle?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        stateDirectory = applicationSupport.appendingPathComponent("ACPMonitor", isDirectory: true)
    }

    var isRunning: Bool { process?.isRunning == true }
    var snapshotURL: URL { stateDirectory.appendingPathComponent("pet-state.json") }

    func start(
        projectPath: String,
        snapshot: PetSnapshot,
        onTermination: @escaping @MainActor (Int32) -> Void
    ) throws {
        stop()
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PetControllerError.projectDirectoryNotFound(projectURL.path)
        }
        let executableURL = projectURL.appendingPathComponent(".build/release/CodexPet")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw PetControllerError.executableNotFound(executableURL.path)
        }

        try write(snapshot)
        let logURL = stateDirectory.appendingPathComponent("pet.log")
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = projectURL
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PET_STATE_FILE": snapshotURL.path,
            "PET_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
            // ACP Monitor owns the complete snapshot. Do not merge the proxy/watcher
            // directory, which would duplicate the same Gateway sessions.
            "PET_AGENT_STATE_DIR": stateDirectory.appendingPathComponent("unused-agent-states").path
        ]) { _, appValue in appValue }
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

    func update(_ snapshot: PetSnapshot) throws {
        try write(snapshot)
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

    private func write(_ snapshot: PetSnapshot) throws {
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
    }
}
