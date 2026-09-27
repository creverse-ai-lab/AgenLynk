import CoreGraphics
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
        try scheduledUpdatesLandInOrderOffTheMainActor()
        try oversizedLogIsRotatedToOneBackup()
        try contractCarriesTheAppNameAndWaitingReason()
        try hoverHitTestPicksTheNearestNodeUnderTheCursor()
        try hoverTextFollowsTheAppWording()
        try hoverBubbleStaysInsideTheWindow()
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
    private static func scheduledUpdatesLandInOrderOffTheMainActor() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let controller = PetController(stateDirectory: workspace.appendingPathComponent("state", isDirectory: true))
        try controller.update(sampleProjection())
        let first = try decodeSequences(controller)
        for _ in 0..<5 { controller.scheduleUpdate(sampleProjection()) { _ in } }
        controller.waitForPendingWrites()
        let last = try decodeSequences(controller)
        guard last.state == last.actions, last.state == first.state + 5 else {
            throw PetControllerCheckError.failed("scheduled writes must land in order with matching sequences")
        }
        try controller.update(sampleProjection())
        guard try decodeSequences(controller).state == last.state + 1 else {
            throw PetControllerCheckError.failed("a synchronous update must follow the scheduled ones")
        }
    }

    @MainActor
    private static func oversizedLogIsRotatedToOneBackup() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let log = workspace.appendingPathComponent("pet.log")
        let backup = workspace.appendingPathComponent("pet.log.1")
        try Data("old backup".utf8).write(to: backup)
        try Data(count: 16).write(to: log)
        PetController.rotateLogIfNeeded(log)
        guard FileManager.default.fileExists(atPath: log.path) else {
            throw PetControllerCheckError.failed("a small log must stay in place")
        }
        try Data(count: PetController.logRotationBytes + 1).write(to: log)
        PetController.rotateLogIfNeeded(log)
        let backupSize = (try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? NSNumber)?.intValue
        guard !FileManager.default.fileExists(atPath: log.path), backupSize == PetController.logRotationBytes + 1 else {
            throw PetControllerCheckError.failed("an oversized log must become the single .1 backup")
        }
    }

    /// The producer names agents the way the app does (nickname, else the
    /// automatic name) and tells permission from input waits — as optional
    /// fields, so a renderer that predates them decodes the file unchanged.
    private static func contractCarriesTheAppNameAndWaitingReason() throws {
        func session(_ id: String, status: String, title: String?, role: String? = nil) throws -> GatewaySession {
            var fields: [String: JSONValue] = [
                "sessionId": .string(id), "provider": .string("claude"), "model": .string("sonnet"),
                "status": .string(status), "cwd": .string("/tmp/AgenLynk"),
                "opener": .string("codex"), "openerInstanceId": .string("codex-main-1"),
                "updatedAt": .string("2026-08-07T00:00:00.000Z")
            ]
            if let title { fields["title"] = .string(title) }
            if let role { fields["role"] = .string(role) }
            guard let session = GatewaySession(.object(fields)) else {
                throw PetControllerCheckError.failed("fixture \(id) did not decode")
            }
            return session
        }
        let sessions = [
            try session("root", status: "running", title: "custom_tool_call/exec", role: "frontdoor"),
            try session("w-titled", status: "waiting_permission", title: "Fix the login test"),
            try session("w-nick", status: "waiting_input", title: "Refactor")
        ]
        let auto = PetActivityProjection.make(sessions: sessions, inbox: [])
        func agent(_ projection: PetActivityProjection, _ id: String) -> PetAgentActivity? {
            projection.agents.first { $0.id == id }
        }
        try expect(agent(auto, "codex-main-1")?.name == "AgenLynk", "a Frontdoor is named by its folder, not a tool-call title")
        try expect(agent(auto, "w-titled")?.name == "Fix the login test", "a Worker is named by its automatic name")

        let nicknamed = PetActivityProjection.make(sessions: sessions, inbox: []) { id, role in
            switch (id, role) {
            case ("w-nick", "worker"): return "  my refactor  "
            case ("codex-main-1", "frontdoor"): return "Release"
            default: return nil
            }
        }
        try expect(agent(nicknamed, "w-nick")?.name == "my refactor", "a Worker nickname wins, trimmed")
        try expect(agent(nicknamed, "codex-main-1")?.name == "Release", "a Frontdoor nickname wins")

        let envelope = PetStateEnvelope.make(projection: nicknamed, sequence: 1)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        let agents = (json?["agents"] as? [[String: Any]]) ?? []
        func encoded(_ id: String) -> [String: Any]? { agents.first { $0["id"] as? String == id } }
        try expect(encoded("w-titled")?["waitingReason"] as? String == "permission", "a permission wait says so")
        try expect(encoded("w-nick")?["waitingReason"] as? String == "input", "an input wait says so")
        try expect(encoded("w-nick")?["name"] as? String == "my refactor", "the name reaches pet-state.json")

        // Nil optional fields are omitted, so the encoded shape of a
        // hand-built agent is exactly the pre-addition one.
        let bare = PetStateEnvelope.make(projection: sampleProjection(), sequence: 1)
        let bareJSON = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        try expect(!bareJSON.contains("\"name\"") && !bareJSON.contains("waitingReason"), "absent optional fields are omitted")
    }

    private static func hoverHitTestPicksTheNearestNodeUnderTheCursor() throws {
        let nodes = [
            PetHoverCandidate(id: "a", center: CGPoint(x: 100, y: 100), radius: 12),
            PetHoverCandidate(id: "b", center: CGPoint(x: 124, y: 100), radius: 12)
        ]
        try expect(petHoveredNodeID(nodes, at: CGPoint(x: 101, y: 102)) == "a", "the node under the cursor is hovered")
        try expect(petHoveredNodeID(nodes, at: CGPoint(x: 113, y: 100)) == "b", "touching nodes: the nearer one wins")
        try expect(petHoveredNodeID(nodes, at: CGPoint(x: 100, y: 116), slop: 6) == "a", "slop forgives a near miss")
        try expect(petHoveredNodeID(nodes, at: CGPoint(x: 100, y: 130)) == nil, "empty space hovers nothing")
        try expect(petHoveredNodeID([], at: .zero) == nil, "no nodes, no hover")

        let hub = CGPoint(x: 500, y: 500)
        try expect(!petHoldReleased(mouse: CGPoint(x: 600, y: 500), hub: hub, reach: 110), "inside the graph the hold stays")
        try expect(petHoldReleased(mouse: CGPoint(x: 700, y: 500), hub: hub, reach: 110), "past the graph the hold releases")
    }

    private static func hoverTextFollowsTheAppWording() throws {
        let phrases = [
            petStatusPhrase(contractState: "running", legacyState: "running", waitingReason: nil),
            petStatusPhrase(contractState: "starting", legacyState: "running", waitingReason: nil),
            petStatusPhrase(contractState: "waiting", legacyState: "needs_input", waitingReason: "permission"),
            petStatusPhrase(contractState: "waiting", legacyState: "needs_input", waitingReason: "input"),
            petStatusPhrase(contractState: "failed", legacyState: "blocked", waitingReason: nil),
            petStatusPhrase(contractState: "idle", legacyState: "idle", waitingReason: nil),
            petStatusPhrase(contractState: "completed", legacyState: "ready", waitingReason: nil),
            petStatusPhrase(contractState: "offline", legacyState: "offline", waitingReason: nil),
            petStatusPhrase(contractState: "unknown", legacyState: "blocked", waitingReason: nil)
        ]
        try expect(phrases == ["실행 중", "실행 중", "권한 대기", "입력 대기", "오류", "대기", "대기", "종료", "알 수 없음"],
                   "contract states use the §3 phrases, got \(phrases)")
        let legacy = ["running", "needs_input", "blocked", "ready", "idle", "offline"].map {
            petStatusPhrase(contractState: nil, legacyState: $0, waitingReason: nil)
        }
        try expect(legacy == ["실행 중", "입력 대기", "오류", "대기", "대기", "종료"], "legacy states are phrased too, got \(legacy)")

        try expect(petRoleLabel(role: "frontdoor", depth: 0) == "Frontdoor", "Frontdoor role")
        try expect(petRoleLabel(role: "worker", depth: 1) == "Worker", "Worker role")
        try expect(petRoleLabel(role: "worker", depth: 2) == "Worker · 2단", "nested Worker role")
        try expect(petProviderLabel("codex") == "Codex" && petProviderLabel("") == "알 수 없는 CLI", "provider display names")

        let text = petHoverText(
            name: "AgenLynk", fallbackName: "ignored", role: "frontdoor", depth: 0,
            status: "실행 중", provider: "claude",
            task: "Implement the hover bubble for the Pet overlay\nwith a second line that must not show"
        )
        try expect(text.title == "AgenLynk" && text.detail == "Frontdoor · 실행 중 · Claude", "title and detail line")
        try expect(text.task?.count == petHoverTaskLimit && text.task?.hasSuffix("…") == true, "the task is one truncated line")
        try expect(text.task?.contains("\n") == false, "the task never wraps")

        let unnamed = petHoverText(
            name: nil, fallbackName: "Run tests", role: "worker", depth: 1,
            status: "대기", provider: "grok", task: "Run tests"
        )
        try expect(unnamed.title == "Run tests" && unnamed.task == nil, "a task equal to the name is not repeated")
        let long = petHoverText(
            name: String(repeating: "n", count: 90), fallbackName: "", role: nil, depth: 0,
            status: "대기", provider: "codex", task: nil
        )
        try expect(long.title.count == petHoverTitleLimit, "a long name is truncated")
    }

    private static func hoverBubbleStaysInsideTheWindow() throws {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let size = CGSize(width: 160, height: 50)
        let above = petBubbleRect(size: size, center: CGPoint(x: 300, y: 300), nodeRadius: 15, bounds: bounds)
        try expect(above.maxY <= 300 - 15, "the bubble sits above the node when there is room")
        try expect(abs(above.midX - 300) < 0.001, "and is centered on it")
        let nearTop = petBubbleRect(size: size, center: CGPoint(x: 300, y: 40), nodeRadius: 15, bounds: bounds)
        try expect(nearTop.minY >= 40 + 15, "near the top it flips below the node")
        let corner = petBubbleRect(size: size, center: CGPoint(x: 590, y: 590), nodeRadius: 15, bounds: bounds)
        try expect(bounds.insetBy(dx: 3.9, dy: 3.9).contains(corner), "it is always clamped inside the window")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PetControllerCheckError.failed(message) }
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
