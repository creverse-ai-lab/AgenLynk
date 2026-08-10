import Darwin
import Foundation

/// G7 boundary checks, run against a REAL child process: the renderer must
/// receive exactly the two contract files and a benign environment — never a
/// secret, never a control channel — and the files themselves must be written
/// atomically with owner-only permissions.
@main
enum PetControllerChecks {
    @MainActor
    static func main() throws {
        try rejectsAnEmptyRendererPath()
        try contractFilesAreOwnerOnlyAndSequenceLocked()
        try rendererEnvironmentCarriesContractFilesButNoSecrets()
        print("Swift Pet controller checks passed")
    }

    @MainActor
    private static func rejectsAnEmptyRendererPath() throws {
        let controller = PetController()
        do {
            try controller.start(
                executablePath: "",
                projection: PetActivityProjection(agents: []),
                onTermination: { _ in }
            )
            throw PetControllerCheckError.failed("an empty renderer path must not be launched")
        } catch PetControllerError.executablePathRequired {
            // Expected: reject in Swift before Foundation receives an invalid
            // Process.currentDirectoryURL and raises NSInvalidArgumentException.
        }
    }

    @MainActor
    private static func contractFilesAreOwnerOnlyAndSequenceLocked() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let controller = PetController(stateDirectory: workspace.appendingPathComponent("state", isDirectory: true))

        try controller.update(sampleProjection())

        let fileManager = FileManager.default
        for url in [controller.stateFileURL, controller.actionsFileURL] {
            guard fileManager.fileExists(atPath: url.path) else {
                throw PetControllerCheckError.failed("missing contract file \(url.lastPathComponent)")
            }
            let permissions = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            guard permissions == 0o600 else {
                throw PetControllerCheckError.failed("\(url.lastPathComponent) must be 0600, got \(String(permissions ?? -1, radix: 8))")
            }
        }
        let directoryPermissions = try fileManager.attributesOfItem(
            atPath: controller.stateFileURL.deletingLastPathComponent().path
        )[.posixPermissions] as? Int
        guard directoryPermissions == 0o700 else {
            throw PetControllerCheckError.failed("the state directory must be 0700")
        }

        // Both files of one update must carry the same sequence, and a second
        // update must advance it in lockstep — the renderer detects torn pairs
        // by exactly this equality.
        let first = try decodeSequences(controller)
        guard first.state == first.actions else {
            throw PetControllerCheckError.failed("state/actions sequences must match within one update")
        }
        try controller.update(sampleProjection())
        let second = try decodeSequences(controller)
        guard second.state == second.actions, second.state > first.state else {
            throw PetControllerCheckError.failed("a new update must advance both sequences together")
        }

        // The state file must never leak internal-only fields.
        let stateText = try String(contentsOf: controller.stateFileURL, encoding: .utf8)
        for forbidden in ["cwd", "inboxPending", "secret-project-path"] where stateText.contains(forbidden) {
            throw PetControllerCheckError.failed("pet-state.json leaked internal field '\(forbidden)'")
        }
    }

    @MainActor
    private static func rendererEnvironmentCarriesContractFilesButNoSecrets() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let controller = PetController(stateDirectory: workspace.appendingPathComponent("state", isDirectory: true))

        // A renderer that simply dumps the environment it was born with.
        let dump = workspace.appendingPathComponent("env-dump.txt")
        let renderer = workspace.appendingPathComponent("fake-renderer.sh")
        try "#!/bin/sh\nenv > \"\(dump.path)\"\nexec /bin/sleep 30\n"
            .write(to: renderer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: renderer.path)

        // Plant secrets in our own environment; the allowlist must drop them.
        setenv("ACP_GATEWAY_CONTROL_TOKEN", "super-secret-token", 1)
        setenv("MONITOR_API_TOKEN", "another-secret", 1)
        defer {
            unsetenv("ACP_GATEWAY_CONTROL_TOKEN")
            unsetenv("MONITOR_API_TOKEN")
        }

        try controller.start(
            executablePath: renderer.path,
            projection: sampleProjection(),
            onTermination: { _ in }
        )
        defer { controller.stop() }
        guard controller.isRunning else {
            throw PetControllerCheckError.failed("the fake renderer should be running")
        }

        // The dump appears as soon as the shell has started.
        var environmentText: String?
        for _ in 0..<200 {
            if let text = try? String(contentsOf: dump, encoding: .utf8), text.contains("PATH=") {
                environmentText = text
                break
            }
            usleep(20_000)
        }
        guard let environmentText else {
            throw PetControllerCheckError.failed("the renderer never wrote its environment dump")
        }

        guard environmentText.contains("PET_STATE_FILE=\(controller.stateFileURL.path)"),
              environmentText.contains("PET_ACTIONS_FILE=\(controller.actionsFileURL.path)") else {
            throw PetControllerCheckError.failed("the renderer must receive both contract file paths")
        }
        for secret in ["ACP_GATEWAY_CONTROL_TOKEN", "MONITOR_API_TOKEN", "super-secret-token", "another-secret"] {
            guard !environmentText.contains(secret) else {
                throw PetControllerCheckError.failed("the renderer environment leaked \(secret)")
            }
        }

        // Stopping the controller must actually take the child down with it.
        let pid = controller.process?.processIdentifier ?? -1
        controller.stop()
        var terminated = false
        for _ in 0..<250 {
            if kill(pid, 0) == -1 && errno == ESRCH {
                terminated = true
                break
            }
            usleep(20_000)
        }
        guard terminated else {
            throw PetControllerCheckError.failed("stop() must terminate the renderer child (pid \(pid))")
        }
    }

    @MainActor
    private static func decodeSequences(_ controller: PetController) throws -> (state: Int, actions: Int) {
        struct SequenceOnly: Decodable { let sequence: Int }
        let state = try JSONDecoder().decode(SequenceOnly.self, from: Data(contentsOf: controller.stateFileURL))
        let actions = try JSONDecoder().decode(SequenceOnly.self, from: Data(contentsOf: controller.actionsFileURL))
        return (state.sequence, actions.sequence)
    }

    private static func sampleProjection() -> PetActivityProjection {
        PetActivityProjection(agents: [
            PetAgentActivity(
                id: "frontdoor-1", parentId: nil, role: "frontdoor", provider: "codex",
                engine: "codex-frontdoor", state: .running, action: .think, task: "Ship v1",
                updatedAt: Date(timeIntervalSince1970: 10), source: "gateway",
                cwd: "/tmp/secret-project-path", inboxPending: 3, memberStates: [.running]
            )
        ])
    }

    private static func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ACPMonitor.PetControllerTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum PetControllerCheckError: Error {
    case failed(String)
}
