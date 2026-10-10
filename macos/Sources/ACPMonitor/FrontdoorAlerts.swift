import Foundation

/// A Frontdoor's Stop held open by the sidecar so the notch can answer it.
struct NotchReplySlot: Equatable {
    let id: String
    let lastMessage: String?
    let expiresAt: Date
    /// Background work the turn left running (Claude): not "done" yet.
    var backgroundTasks = 0
}

/// What the notch pops out for: a Frontdoor that now needs the person, or
/// one whose work just ended. Workers alert through their Frontdoor.
struct NotchAlert: Identifiable, Equatable {
    enum Kind: Equatable { case permission, input, done, failed }

    let id = UUID()
    let createdAt = Date()
    let kind: Kind
    let frontdoorId: String
    /// The session to open: the waiting member, else the Frontdoor's root.
    let sessionId: String?
    let provider: String
    let title: String
    /// Set when the finished Frontdoor is still listening for a reply.
    var reply: NotchReplySlot? = nil
    /// Replaces the kind's usual message.
    var note: String? = nil

    /// Waiting alerts stay until the Frontdoor moves on, a reply box until
    /// its window closes; the others fade.
    var isSticky: Bool { kind == .permission || kind == .input || reply != nil }

    var message: String {
        if let note { return note }
        return switch kind {
        case .permission: "권한 요청을 기다리고 있어요"
        case .input: "입력을 기다리고 있어요"
        // With a reply box the CLI is still holding its turn open for us, so
        // this says so rather than claiming the work is finished.
        case .done:
            if let reply, reply.backgroundTasks > 0 { "턴 종료 · 백그라운드 작업 \(reply.backgroundTasks)개 진행 중" }
            else if reply != nil { "턴을 마쳤어요 · 답장을 기다리는 중" }
            else { "작업을 마쳤어요" }
        case .failed: "작업이 실패했어요"
        }
    }
}

/// A Frontdoor's state, read the way the person cares about it: anyone
/// waiting on them first, then running, then how the last work ended.
enum FrontdoorPhase: Equatable {
    case waitingPermission, waitingInput, running, failed, idle, other

    static func of(_ frontdoor: FrontdoorSession) -> FrontdoorPhase {
        let statuses = Set(members(frontdoor).map(\.status))
        if statuses.contains("waiting_permission") { return .waitingPermission }
        if statuses.contains("waiting_input") { return .waitingInput }
        // Sleeping on its Workers is still the turn in flight: no "done".
        if !statuses.isDisjoint(with: ["running", "waiting_tasks", "cancelling", "restoring"]) { return .running }
        // How the work ended is the root's to say; a Worker failing alone
        // does not fail the Frontdoor's turn.
        switch frontdoor.root?.status ?? "" {
        case "error", "cancelled", "unavailable": return .failed
        case "idle", "ready": return .idle
        default: return .other
        }
    }

    static func members(_ frontdoor: FrontdoorSession) -> [GatewaySession] {
        (frontdoor.root.map { [$0] } ?? []) + frontdoor.workers
    }
}

/// Turns successive Frontdoor snapshots into alerts. The first snapshot only
/// records where everything stands, so launching the app does not replay
/// every Frontdoor that was already waiting or finished.
struct FrontdoorAlertTracker {
    private var phases: [String: FrontdoorPhase] = [:]
    private var primed = false

    mutating func update(_ frontdoors: [FrontdoorSession]) -> [NotchAlert] {
        // An empty list is "not loaded yet" or a reconnect in progress, not
        // every Frontdoor gone: priming on it (or forgetting the phases)
        // would replay every wait once the real list arrives.
        guard !frontdoors.isEmpty else { return [] }
        var alerts: [NotchAlert] = []
        var next: [String: FrontdoorPhase] = [:]
        for frontdoor in frontdoors where !frontdoor.isUnattributed {
            let phase = FrontdoorPhase.of(frontdoor)
            next[frontdoor.id] = phase
            guard primed, let kind = Self.alertKind(from: phases[frontdoor.id], to: phase) else { continue }
            let waiting = FrontdoorPhase.members(frontdoor).first { $0.status == "waiting_permission" || $0.status == "waiting_input" }
            alerts.append(NotchAlert(
                kind: kind,
                frontdoorId: frontdoor.id,
                sessionId: waiting?.sessionId ?? frontdoor.root?.sessionId,
                provider: frontdoor.provider,
                title: frontdoor.displayName
            ))
        }
        phases = next
        primed = true
        return alerts
    }

    /// Entering a wait always alerts; finishing alerts only when this app saw
    /// the work running, so a Frontdoor that merely appears idle stays quiet.
    static func alertKind(from previous: FrontdoorPhase?, to phase: FrontdoorPhase) -> NotchAlert.Kind? {
        guard previous != phase else { return nil }
        switch phase {
        case .waitingPermission: return .permission
        case .waitingInput: return .input
        case .idle: return previous == .running ? .done : nil
        case .failed: return previous == .running ? .failed : nil
        case .running, .other: return nil
        }
    }
}
