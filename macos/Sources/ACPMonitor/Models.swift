import ACPShared
import Foundation

enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(any value: Any) {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value): value.formatted()
        case let .bool(value): value ? "true" : "false"
        default: nil
        }
    }

    var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        return Int(value)
    }

    var doubleValue: Double? {
        guard case let .number(value) = self, value.isFinite else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var foundationValue: Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .object(value): value.mapValues(\.foundationValue)
        case let .array(value): value.map(\.foundationValue)
        case .null: NSNull()
        }
    }

    var prettyPrinted: String {
        guard JSONSerialization.isValidJSONObject(foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return stringValue ?? "null"
        }
        return text
    }

    /// Single-line JSON, for quoting a small structured value (a tool's
    /// arguments) inside otherwise human-readable text. Slashes stay
    /// unescaped: the values quoted this way are mostly paths, and `\/` reads
    /// as noise in a sentence.
    var compactPrinted: String {
        guard JSONSerialization.isValidJSONObject(foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return stringValue ?? "null"
        }
        return text
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func object(_ key: String) -> [String: JSONValue]? { self[key]?.objectValue }
    func array(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }
}

struct GatewaySession: Identifiable, Hashable, Sendable {
    let sessionId: String
    let provider: String
    let model: String?
    private(set) var status: String
    let title: String?
    let opener: String?
    let openerInstanceId: String?
    let cwd: String
    let turnId: String?
    let stopReason: String?
    let createdAt: String?
    let updatedAt: String?
    let eventCount: Int
    let source: String
    let role: String
    let parentSessionId: String?
    /// Token usage as the sidecar normalizes it for every provider; nil when
    /// the source reports none.
    let usage: SessionUsage?
    /// The totals cover only the part of a long transcript that was read.
    let usagePartial: Bool
    /// What the monitor can actually observe for this session (`status`,
    /// `timeline`, `tools`, `thinking`, `usage`, `permission`, `live`), so an
    /// empty timeline can be told apart from a source that cannot see one.
    let capabilities: Set<String>
    /// Warnings the app must show, e.g. `permission_policy_partial`: a
    /// read_only/ask Codex session can still edit inside its roots.
    let alerts: [SessionAlert]
    /// Recent turns' token use, newest last (contracts/monitor/v2 turnUsage).
    let turnUsage: [TurnUsage]

    var id: String { sessionId }
    /// Naming policy (docs/ux-policy.md): the sidecar's title (the CLI's own
    /// title, else the latest prompt), else "<Provider> · <folder>". A raw
    /// session id is never a name; it stays available in tooltips.
    /// A title that is the CLI's current tool call / event path
    /// ("custom_tool_call/exec") is skipped, like a Frontdoor's.
    var displayName: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
           !isToolishTitle(title) { return title }
        // The provider is the icon beside the name, so it is not repeated in
        // the text; the folder tells the session apart.
        let folder = (cwd as NSString).lastPathComponent
        if !cwd.isEmpty, !folder.isEmpty, folder != "/" { return folder }
        return "새 세션"
    }
    var providerLabel: String { providerDisplayLabel(provider) }
    var isFrontdoorRecord: Bool { role == "frontdoor" }
    var isLocalSource: Bool { source == "local" }
    var sourceLabel: String { isLocalSource ? "LOCAL" : "ACP" }
    var isInternalReview: Bool {
        let identity = "\(model ?? "") \(title ?? "")".lowercased()
        return identity.contains("auto-review") || identity.contains("auto_review")
    }
    var isActive: Bool {
        ["running", "waiting_permission", "waiting_input", "cancelling", "restoring"].contains(status)
    }
    var hasFrontdoorIdentity: Bool {
        openerInstanceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    var isRealtimeVisible: Bool { isActive && hasFrontdoorIdentity }
    /// Updates arrive as they happen (hooks or the Gateway stream), not only
    /// from a transcript re-read.
    /// A closed (or history) session is no longer updating, so it never
    /// claims to be live.
    var isLiveObserved: Bool { capabilities.contains("live") && status != "closed" }
    /// The "실시간" badge: only for a session still in the live snapshot. A
    /// history session (browsed from disk, or moved to history when its idle
    /// hold ran out) keeps its `live` capability but is no longer updating.
    func showsRealtimeBadge(inHistory: Bool) -> Bool { !inHistory && isLiveObserved }
    /// "권한 대기 감지 불가 (hook 꺼짐)" explains a live session's empty
    /// permission state; a finished or history session has none to explain.
    func showsPermissionBlindNote(inHistory: Bool) -> Bool {
        !inHistory && status != "closed" && cannotObservePermission
    }
    /// The source can see an event timeline at all. A record without
    /// capabilities (older sidecar) is assumed to.
    var canShowTimeline: Bool { capabilities.isEmpty || capabilities.contains("timeline") }
    /// Waiting on the person: a permission prompt or a question.
    var isWaitingForUser: Bool { status == "waiting_permission" || status == "waiting_input" }
    /// The source cannot see a permission prompt, so "nothing is waiting" is
    /// not something this session can tell. A record without capabilities
    /// (older sidecar) and a Gateway session are never flagged.
    var cannotObservePermission: Bool {
        guard !capabilities.isEmpty, isLocalSource else { return false }
        return !capabilities.contains("permission")
    }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let sessionId = object.string("sessionId") else { return nil }
        self.sessionId = sessionId
        provider = object.string("provider") ?? "unknown"
        model = object.string("model")
        status = object.string("status") ?? "unknown"
        title = object.string("title")
        opener = object.string("opener")
        openerInstanceId = object.string("openerInstanceId")
        cwd = object.string("cwd") ?? ""
        turnId = object.string("turnId")
        stopReason = object.string("stopReason")
        createdAt = object.string("createdAt")
        updatedAt = object.string("updatedAt")
        eventCount = object.int("eventCount") ?? 0
        source = object.string("source") ?? "gateway"
        role = object.string("role") ?? "worker"
        parentSessionId = object.string("parentSessionId")
        usage = SessionUsage(object["usage"])
        usagePartial = object.bool("usagePartial") ?? false
        capabilities = Set((object.array("capabilities") ?? []).compactMap { item -> String? in
            guard case let .string(name) = item else { return nil }
            return name
        })
        alerts = (object.array("alerts") ?? []).compactMap(SessionAlert.init)
        turnUsage = (object.array("turnUsage") ?? []).compactMap(TurnUsage.init)
    }

    /// `base` followed by the model id when the session reports one. v2 sends
    /// a real model id or nil — never a placeholder — so nil shows nothing
    /// rather than a made-up "default".
    func withModel(_ base: String, separator: String = " · ") -> String {
        guard let model, !model.isEmpty else { return base }
        return base + separator + model
    }

    /// The same record with another status — used when a stream frame says a
    /// session closed before the next snapshot restates it.
    func with(status: String) -> GatewaySession {
        var copy = self
        copy.status = status
        return copy
    }
}

struct TurnUsage: Hashable, Sendable {
    let turnId: String
    let startedAt: String?
    let running: Bool
    let totalTokens: Double?
    let outputTokens: Double?
    let contextUsed: Double?

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let turnId = object.string("turnId") else { return nil }
        self.turnId = turnId
        startedAt = object.string("startedAt")
        running = object.bool("running") ?? false
        totalTokens = object.double("totalTokens")
        outputTokens = object.double("outputTokens")
        contextUsed = object.double("contextUsed")
    }
}

/// What a session (or a whole Frontdoor's work) has used and is likely to
/// use. The estimate is the median of completed turns — shown only with at
/// least two, so one odd turn does not pass for a pattern.
struct UsageForecast: Equatable, Sendable {
    /// The running turn's tokens so far; nil when the provider settles a turn
    /// only at its end (Grok) or nothing is running.
    let currentTurnTokens: Double?
    let currentTurnRunning: Bool
    let currentTurnStartedAt: String?
    let typicalTurnTokens: Double?
    let completedTurns: Int
    /// Turns left before the context window fills at the recent growth rate.
    let turnsUntilContextFull: Int?

    init(session: GatewaySession) {
        let turns = session.turnUsage
        let running = turns.last(where: \.running)
        currentTurnRunning = running != nil
        currentTurnTokens = running?.totalTokens
        currentTurnStartedAt = running?.startedAt
        let completed = turns.filter { !$0.running }.compactMap(\.totalTokens)
        completedTurns = completed.count
        typicalTurnTokens = completed.count >= 2 ? Self.median(completed) : nil
        let contexts = turns.compactMap(\.contextUsed)
        let growth = zip(contexts, contexts.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        if let window = session.usage?.contextWindow, let used = session.usage?.contextUsed ?? contexts.last,
           growth.count >= 2, let step = Self.median(growth), step > 0, window > used {
            turnsUntilContextFull = Int(((window - used) / step).rounded(.down))
        } else {
            turnsUntilContextFull = nil
        }
    }

    /// How far the running turn is against the typical one (may exceed 1).
    var progress: Double? {
        guard let current = currentTurnTokens, let typical = typicalTurnTokens, typical > 0 else { return nil }
        return current / typical
    }

    /// "예상의 80%", "예상의 150%" — a share of the estimate, never an
    /// ambiguous "초과 150%".
    var progressText: String? {
        progress.map { "예상의 \(Int(($0 * 100).rounded()))%" }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// One Frontdoor's work: its root and workers added up.
struct WorkUsage: Equatable, Sendable {
    let totalTokens: Double?
    let currentTurnTokens: Double?
    let runningSessions: Int
    /// Running turns without tokens yet — their provider settles a turn only
    /// at its end (Grok), so they are left out of `currentTurnTokens`.
    let settlingSessions: Int

    init(sessions: [GatewaySession]) {
        let totals = sessions.compactMap { $0.usage?.total }
        totalTokens = totals.isEmpty ? nil : totals.reduce(0, +)
        let running = sessions.compactMap { session in session.turnUsage.last(where: \.running) }
        runningSessions = running.count
        let current = running.compactMap(\.totalTokens)
        settlingSessions = running.count - current.count
        currentTurnTokens = current.isEmpty ? nil : current.reduce(0, +)
    }

    /// The Frontdoor's "이번 턴" pill: the running turns' sum, or "이번 턴 집계
    /// 중" while every running turn is still unsettled; nil when none runs.
    var currentTurnText: String? {
        if let currentTurnTokens { return "이번 턴 \(formatTokenCount(currentTurnTokens))" }
        return runningSessions > 0 ? "이번 턴 집계 중" : nil
    }

    /// What the pill's number covers, naming the sessions left out of it.
    var currentTurnHelp: String? {
        guard runningSessions > 0 else { return nil }
        if currentTurnTokens == nil { return "이 CLI는 턴이 끝날 때 토큰을 확정합니다." }
        if settlingSessions > 0 { return "토큰이 턴 끝에 확정되는 세션 \(settlingSessions)개는 합계에서 빠져 있습니다." }
        return "지금 실행 중인 턴 \(runningSessions)개가 지금까지 쓴 토큰입니다."
    }
}

struct SessionAlert: Hashable, Sendable {
    let level: String
    let code: String
    let message: String?

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let code = object.string("code") else { return nil }
        self.code = code
        level = object.string("level") ?? "warning"
        message = object.string("message")
    }

    /// A short badge; the full message is the tooltip. An unknown code is
    /// never shown raw.
    var badge: String {
        code == "permission_policy_partial" ? "읽기 전용 부분 적용" : "경고"
    }

    var tooltip: String {
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty { return message }
        return "자세한 설명이 없는 경고입니다."
    }
}

/// Session token usage (contracts/monitor/v2 `usage`). Same meaning for every
/// provider: input includes cached input, total = input + output, reasoning
/// is part of output, and `contextUsed` is the prompt size of the latest model
/// call. A nil field means the provider did not say — never zero.
struct SessionUsage: Hashable, Sendable {
    let inputTokens: Double?
    let outputTokens: Double?
    let cacheReadTokens: Double?
    let cacheWriteTokens: Double?
    let reasoningTokens: Double?
    let totalTokens: Double?
    let contextUsed: Double?
    let contextWindow: Double?
    let costUsd: Double?

    /// nil unless the value is an object carrying at least one known number.
    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue else { return nil }
        inputTokens = object.double("inputTokens")
        outputTokens = object.double("outputTokens")
        cacheReadTokens = object.double("cacheReadTokens")
        cacheWriteTokens = object.double("cacheWriteTokens")
        reasoningTokens = object.double("reasoningTokens")
        totalTokens = object.double("totalTokens")
        contextUsed = object.double("contextUsed")
        contextWindow = object.double("contextWindow")
        costUsd = object.double("costUsd")
        let known: [Double?] = [
            inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens,
            totalTokens, contextUsed, contextWindow, costUsd
        ]
        if known.allSatisfy({ $0 == nil }) { return nil }
    }

    /// Input + output when the provider left the total out.
    var total: Double? {
        totalTokens ?? inputTokens.flatMap { input in outputTokens.map { input + $0 } }
    }

    /// Share of the context window in use, 0...1, only when both are known.
    var contextFraction: Double? {
        guard let contextUsed, let contextWindow, contextWindow > 0 else { return nil }
        return min(max(contextUsed / contextWindow, 0), 1)
    }
}

/// Compact token count for small labels: 950, 12.3K, 1.2M.
func formatTokenCount(_ value: Double) -> String {
    let magnitude = abs(value)
    if magnitude >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if magnitude >= 10_000 { return String(format: "%.0fK", value / 1_000) }
    if magnitude >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    return String(Int(value.rounded()))
}

struct FrontdoorSession: Identifiable, Hashable, Sendable {
    let id: String
    let provider: String
    let root: GatewaySession?
    let workers: [GatewaySession]
    /// The newest member update, computed once: sort comparators and card
    /// ordering read it many times per pass.
    let updatedAt: String?

    init(id: String, provider: String, root: GatewaySession?, workers: [GatewaySession]) {
        self.id = id
        self.provider = provider
        self.root = root
        self.workers = workers
        updatedAt = ((root.map { [$0] } ?? []) + workers).compactMap(\.updatedAt).max()
    }

    /// The working folder names the Frontdoor — it is stable and meaningful,
    /// and it is what tells two concurrent Frontdoors apart. A designated title
    /// is only used when there is no folder, and only if it is a real name:
    /// a local CLI writes its *current tool call* into its title
    /// ("custom_tool_call/exec"), which as a name is worse than useless.
    var displayName: String {
        if isUnattributed { return "연결 미확인 Worker" }
        if let folder = workingFolder { return folder }
        if let name = designatedName { return name }
        return "이름 없는 작업"
    }
    /// The root's title, but only when it reads as a name rather than the
    /// transient event/tool text local sessions park there.
    private var designatedName: String? {
        guard let title = root?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              !isToolishTitle(title) else { return nil }
        return title
    }
    /// Last path component of the Frontdoor's working directory, or nil when no
    /// member reports one.
    var workingFolder: String? {
        let cwd = root?.cwd.isEmpty == false ? root!.cwd : members.first { !$0.cwd.isEmpty }?.cwd
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
    var members: [GatewaySession] { (root.map { [$0] } ?? []) + workers }
    var isActive: Bool { members.contains(where: \.isActive) }
    /// Members actually running — a session waiting on the person is not.
    var runningCount: Int { members.filter { $0.isActive && !$0.isWaitingForUser }.count }
    var waitingPermissionCount: Int { members.filter { $0.status == "waiting_permission" }.count }
    var waitingInputCount: Int { members.filter { $0.status == "waiting_input" }.count }
    /// Every member closed: the work is over, not just idle.
    var isClosed: Bool { !members.isEmpty && members.allSatisfy { $0.status == "closed" } }
    /// The member a selection of this Frontdoor should land on: one waiting
    /// on the person first, else the root, else the first worker.
    var preferredSession: GatewaySession? {
        members.first(where: { $0.status == "waiting_permission" })
            ?? members.first(where: { $0.status == "waiting_input" })
            ?? root ?? workers.first
    }
    /// The status pill: waiting first (it needs the person), then running,
    /// closed, idle.
    var statusText: String {
        let waits = [
            waitingPermissionCount > 0 ? "권한 대기 \(waitingPermissionCount)" : nil,
            waitingInputCount > 0 ? "입력 대기 \(waitingInputCount)" : nil
        ].compactMap { $0 }
        if !waits.isEmpty { return waits.joined(separator: " · ") }
        if isActive { return "실행 중" }
        if isClosed { return "종료" }
        return "대기"
    }
    /// The status the pill's color follows (see statusColor).
    var statusKey: String {
        if waitingPermissionCount > 0 { return "waiting_permission" }
        if waitingInputCount > 0 { return "waiting_input" }
        if isActive { return "running" }
        if isClosed { return "closed" }
        return "idle"
    }
    /// The sidebar row's second line: "Worker 2 · 실행 중 2 · 작업 토큰 34K".
    var countsLine: String {
        var parts = ["Worker \(workers.count)", "실행 중 \(runningCount)"]
        if let total = WorkUsage(sessions: members).totalTokens { parts.append("작업 토큰 \(formatTokenCount(total))") }
        return parts.joined(separator: " · ")
    }
    var activeWorkerCount: Int { workers.filter(\.isActive).count }
    var workspaceCount: Int { Set(members.map(\.cwd).filter { !$0.isEmpty }).count }
    var latestTask: String? {
        members
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            .compactMap(\.title)
            .first { !$0.isEmpty }
    }

    /// Workers the Gateway reports without a known opener (an older daemon,
    /// or a Main whose transcript this Mac cannot see). They are never promoted
    /// to Frontdoors, but they must not vanish either: they share one group.
    static let unattributedId = "unattributed"
    var isUnattributed: Bool { id == Self.unattributedId }

    static func make(sessions: [GatewaySession]) -> [FrontdoorSession] {
        let mapped = sessions.filter(\.hasFrontdoorIdentity)
        let orphans = sessions.filter { !$0.hasFrontdoorIdentity && !$0.isFrontdoorRecord }
        let unattributed = orphans.isEmpty ? [] : [FrontdoorSession(
            id: unattributedId,
            provider: orphans.first?.provider.lowercased() ?? "agent",
            root: nil,
            workers: orphans.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        )]
        return Dictionary(grouping: mapped, by: { $0.openerInstanceId! })
            .map { instanceId, members in
                let roots = members.filter(\.isFrontdoorRecord)
                let root = roots.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }
                let workers = members.filter { !$0.isFrontdoorRecord }
                let opener = root?.provider ?? workers.compactMap(\.opener).first { !$0.isEmpty } ?? "unknown"
                return FrontdoorSession(
                    id: instanceId,
                    provider: opener.lowercased(),
                    root: root,
                    workers: workers.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
                )
            }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            + unattributed
    }
}

// MARK: - Pet contract v1

/// Normalized agent activity state for the Pet/user-renderer JSON contract
/// (`contracts/pet/v1/pet-state.schema.json`). This vocabulary is frozen by
/// the contract and is intentionally distinct from `PetSnapshot`'s in-app
/// graph state strings, which back the existing Agent Map view.
enum PetAgentState: String, Encodable, Equatable, Sendable {
    case offline, idle, starting, running, waiting, completed, failed, unknown
}

/// Presentation action a Pet/user-renderer is asked to play, per
/// `contracts/pet/v1/pet-actions.schema.json`.
enum PetPresentationAction: String, Encodable, Equatable, Sendable {
    case sleep, wake, think, useTool, waitForUser, celebrate, error, disconnect, unknown
}

/// One Frontdoor or Worker agent projected for the Pet contract. `cwd`,
/// `inboxPending`, and `memberStates` are internal-only: they back the
/// legacy `PetSnapshot`/Agent Map projection and are never encoded into
/// `pet-state.json`/`pet-actions.json`, which only expose the fields their
/// schema declares.
struct PetAgentActivity: Equatable, Sendable {
    let id: String
    let parentId: String?
    let role: String
    let provider: String
    let engine: String
    let state: PetAgentState
    let action: PetPresentationAction
    let task: String?
    let updatedAt: Date
    let source: String
    let cwd: String?
    let inboxPending: Int
    /// Frontdoor entries only: every raw member's own (non-aggregated)
    /// contract state, so a legacy aggregation can be re-run without
    /// re-classifying raw Gateway statuses.
    let memberStates: [PetAgentState]
    /// Why a waiting agent waits ("permission" or "input"): the Pet contract
    /// folds both into `waiting`, the menu bar tells them apart.
    var waitingReason: String? = nil
}

/// "permission" / "input" for a waiting status, else nil.
func waitingReason(for statuses: [String]) -> String? {
    if statuses.contains("waiting_permission") { return "permission" }
    if statuses.contains("waiting_input") { return "input" }
    return nil
}

/// The common activity projection both `pet-state.json`/`pet-actions.json`
/// and the legacy `PetSnapshot` (Agent Map) are derived from, so every
/// consumer classifies a raw Gateway/local-monitor status exactly once.
struct PetActivityProjection: Equatable, Sendable {
    let agents: [PetAgentActivity]

    static func make(
        sessions: [GatewaySession],
        inbox: [MonitorRecord],
        now: Date = Date()
    ) -> PetActivityProjection {
        let pendingBySession = Dictionary(grouping: inbox.filter {
            $0.status == "pending" && $0.payload.objectValue?.string("sessionId") != nil
        }, by: {
            $0.payload.objectValue!.string("sessionId")!
        }).mapValues(\.count)

        let groups = Dictionary(grouping: sessions) { gatewaySession in
            FrontdoorKey(
                provider: normalizedFrontdoor(gatewaySession.opener),
                cwd: gatewaySession.cwd,
                instanceId: gatewaySession.openerInstanceId
            )
        }
        var agents: [PetAgentActivity] = []
        for key in groups.keys.sorted(by: { lhs, rhs in
            lhs.provider == rhs.provider ? lhs.cwd < rhs.cwd : lhs.provider < rhs.provider
        }) {
            guard let group = groups[key] else { continue }
            let root = group.filter(\.isFrontdoorRecord)
                .max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }
            let workers = group.filter { !$0.isFrontdoorRecord }
            let frontdoorId = key.instanceId ?? petFrontdoorId(key)
            // Lexical comparison: every producer emits the same fixed-width
            // ISO8601 form, so string order is time order (FrontdoorSession.make
            // relies on exactly this). Parsing dates on both sides of every
            // max() comparison was ~90% of this whole projection's cost.
            let latest = group.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }
            let memberStates = group.map { session in
                petContractState(for: session.status, hasPendingInbox: (pendingBySession[session.sessionId] ?? 0) > 0)
            }
            let frontdoorState = frontdoorContractState(memberStates)
            let frontdoorCwd = root?.cwd ?? key.cwd
            agents.append(PetAgentActivity(
                id: frontdoorId,
                parentId: nil,
                role: "frontdoor",
                provider: root?.provider ?? key.provider,
                engine: root?.model ?? "\(key.provider)-frontdoor",
                state: frontdoorState,
                action: petContractAction(for: frontdoorState),
                task: boundedTaskText(root?.title ?? "Frontdoor"),
                updatedAt: Date(timeIntervalSince1970: petTimestamp(root?.updatedAt ?? latest?.updatedAt, fallback: now)),
                source: root?.source ?? (group.allSatisfy(\.isLocalSource) ? "local" : "gateway"),
                cwd: frontdoorCwd.isEmpty ? nil : frontdoorCwd,
                inboxPending: 0,
                memberStates: memberStates,
                waitingReason: waitingReason(for: group.map(\.status))
            ))
            agents.append(contentsOf: workers.map { gatewaySession in
                let pending = pendingBySession[gatewaySession.sessionId] ?? 0
                let state = petContractState(for: gatewaySession.status, hasPendingInbox: pending > 0)
                return PetAgentActivity(
                    id: gatewaySession.sessionId,
                    parentId: frontdoorId,
                    role: "worker",
                    provider: gatewaySession.provider,
                    engine: gatewaySession.model ?? gatewaySession.provider,
                    state: state,
                    action: petContractAction(for: state),
                    task: boundedTaskText(gatewaySession.title),
                    updatedAt: Date(timeIntervalSince1970: petTimestamp(gatewaySession.updatedAt, fallback: now)),
                    source: gatewaySession.source,
                    cwd: gatewaySession.cwd.isEmpty ? nil : gatewaySession.cwd,
                    inboxPending: pending,
                    memberStates: [],
                    waitingReason: waitingReason(for: [gatewaySession.status])
                )
            })
        }
        return PetActivityProjection(agents: agents)
    }

    /// Agents ordered for a progress-at-a-glance surface: anything in flight
    /// first, then newest-first so a just-finished turn stays visible. Shared
    /// so the menu bar and any other status surface rank states identically.
    var orderedByProgress: [PetAgentActivity] {
        agents.sorted { lhs, rhs in
            let lhsRank = lhs.state.progressRank
            let rhsRank = rhs.state.progressRank
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

extension PetAgentState {
    /// Lower ranks are more "in progress". Ordering only — the contract
    /// state values themselves stay exactly as `pet-state.schema.json`
    /// declares them.
    var progressRank: Int {
        switch self {
        case .running: 0
        case .waiting: 1
        case .starting: 2
        case .failed: 3
        case .completed: 4
        case .idle: 5
        case .offline: 6
        case .unknown: 7
        }
    }
}

/// Maps a raw Gateway/local-monitor session status onto the contract's
/// frozen 8-value state vocabulary. Covers every literal status produced by
/// `src/gateway-service.js` and `sidecar/src/local-monitor.js`. This is the single
/// classifier both the Pet contract and the legacy `PetSnapshot` derive
/// their per-agent state from — a cancelled or errored turn is never
/// reported as `.completed`.
private func petContractState(for status: String, hasPendingInbox: Bool) -> PetAgentState {
    if hasPendingInbox { return .waiting }
    switch status {
    case "running", "cancelling": return .running
    case "restoring": return .starting
    case "waiting_permission", "waiting_input": return .waiting
    case "idle": return .idle
    // Pre-v2 local sessions said "ready"; v2 sends the Gateway's "idle".
    case "ready": return .completed
    case "disconnected", "closed": return .offline
    case "cancelled", "error", "unavailable": return .failed
    default: return .unknown
    }
}

/// A Frontdoor root is only as settled as its least-settled member; the
/// first matching state in this priority order wins.
private func frontdoorContractState(_ memberStates: [PetAgentState]) -> PetAgentState {
    let priority: [PetAgentState] = [.waiting, .running, .starting, .failed, .idle, .completed, .offline]
    for state in priority where memberStates.contains(state) { return state }
    return .unknown
}

/// The contract carries no per-event tool-call evidence, so a running
/// agent is presented as thinking rather than assumed to be using a tool.
/// `useTool` stays a valid, frozen enum value for a future projection that
/// does have that evidence.
private func petContractAction(for state: PetAgentState) -> PetPresentationAction {
    switch state {
    case .offline: .disconnect
    case .idle: .sleep
    case .starting: .wake
    case .running: .think
    case .waiting: .waitForUser
    case .completed: .celebrate
    case .failed: .error
    case .unknown: .unknown
    }
}

/// Trims and bounds task text before it leaves the process boundary — the
/// Pet renderer must never receive a full prompt or unbounded event text.
private func boundedTaskText(_ text: String?) -> String? {
    guard let text else { return nil }
    let collapsed = oneLineText(text, limit: 200, ellipsis: false)
    return collapsed.isEmpty ? nil : collapsed
}

/// The one line a label shows of any text: newlines become spaces, the ends
/// are trimmed, and past `limit` characters it is cut (with "…" unless
/// `ellipsis` is false). Every row, tooltip and contract field that shortens
/// text goes through here.
func oneLineText(_ text: String, limit: Int? = nil, ellipsis: Bool = true) -> String {
    let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let limit, line.count > limit else { return line }
    let cut = String(line.prefix(limit))
    return ellipsis ? cut.trimmingCharacters(in: .whitespaces) + "…" : cut
}

/// The Agent Map's legacy state/graph projection. Unchanged in shape and
/// behavior from before the v1 Pet contract; now derived from the same
/// `PetActivityProjection` classifier instead of a second copy of the
/// status-mapping logic.
struct PetSnapshot: Encodable, Equatable, Sendable {
    struct Session: Encodable, Equatable, Sendable {
        let provider: String
        let session: String
        let state: String
        let parent: String?
        let engine: String
        let time: TimeInterval
        let inboxPending: Int
        let cwd: String?
        let task: String?
        let delegated: Bool
        let role: String?
        let source: String

        enum CodingKeys: String, CodingKey {
            case provider, session, state, parent, engine, time, cwd, task, delegated, role, source
            case inboxPending = "inbox_pending"
        }
    }

    let sessions: [Session]

    static func make(
        sessions: [GatewaySession],
        inbox: [MonitorRecord],
        now: Date = Date()
    ) -> PetSnapshot {
        let projection = PetActivityProjection.make(sessions: sessions, inbox: inbox, now: now)
        let projected = projection.agents.map { agent -> Session in
            let legacyState = agent.role == "frontdoor"
                ? legacyAggregate(agent.memberStates.map(legacyPetState))
                : legacyPetState(agent.state)
            return Session(
                provider: agent.provider,
                session: agent.id,
                state: legacyState,
                parent: agent.parentId,
                engine: agent.engine,
                time: agent.updatedAt.timeIntervalSince1970,
                inboxPending: agent.inboxPending,
                cwd: agent.cwd,
                task: agent.task,
                delegated: agent.role == "worker",
                role: agent.role,
                source: agent.source
            )
        }
        return PetSnapshot(sessions: projected)
    }
}

/// Reverse-maps the contract's per-agent state onto the Agent Map's
/// pre-v1-contract vocabulary. A pure function of `PetAgentState`, not the
/// raw status, so classification stays centralized in `petContractState`.
private func legacyPetState(_ state: PetAgentState) -> String {
    switch state {
    case .running, .starting: "running"
    case .waiting: "needs_input"
    case .idle: "idle"
    case .completed: "ready"
    case .offline: "offline"
    case .failed, .unknown: "blocked"
    }
}

/// The Agent Map's original Frontdoor roll-up rule, unchanged: any
/// busy-or-needs-attention member keeps the whole tree "running".
private func legacyAggregate(_ states: [String]) -> String {
    if states.contains(where: { $0 == "running" || $0 == "needs_input" }) { return "running" }
    if states.contains("blocked") { return "blocked" }
    if states.contains("idle") { return "idle" }
    return "offline"
}

private struct FrontdoorKey: Hashable {
    let provider: String
    let cwd: String
    let instanceId: String?

    private var identity: String { instanceId ?? "\(provider)\u{0}\(cwd)" }

    static func == (lhs: FrontdoorKey, rhs: FrontdoorKey) -> Bool {
        lhs.identity == rhs.identity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }
}

private func normalizedFrontdoor(_ opener: String?) -> String {
    let value = opener?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return value.isEmpty ? "unknown" : value
}

private func petFrontdoorId(_ key: FrontdoorKey) -> String {
    if let instanceId = key.instanceId, !instanceId.isEmpty { return instanceId }
    let identity = "\(key.provider)\u{0}\(key.cwd)"
    return "frontdoor:\(Data(identity.utf8).base64EncodedString())"
}

private func petTimestamp(_ value: String?, fallback: Date) -> TimeInterval {
    guard let value else { return fallback.timeIntervalSince1970 }
    return parseTimestamp(value)?.timeIntervalSince1970 ?? fallback.timeIntervalSince1970
}

/// `contracts/pet/v1/pet-state.schema.json` envelope.
struct PetStateEnvelope: Encodable, Equatable, Sendable {
    struct Agent: Encodable, Equatable, Sendable {
        let id: String
        let parentId: String?
        let role: String
        let provider: String
        let engine: String
        let state: PetAgentState
        let task: String?
        let updatedAt: String
        let source: String
    }

    let contract: String
    let version: String
    let generatedAt: String
    let producer: String
    let sequence: Int
    let agents: [Agent]

    static func make(
        projection: PetActivityProjection,
        sequence: Int,
        producer: String = "lynk-monitor",
        generatedAt: Date = Date()
    ) -> PetStateEnvelope {
        PetStateEnvelope(
            contract: "pet-state",
            version: "1.0.0",
            generatedAt: monitorTimestamp(generatedAt),
            producer: producer,
            sequence: sequence,
            agents: projection.agents.map { agent in
                Agent(
                    id: agent.id,
                    parentId: agent.parentId,
                    role: agent.role,
                    provider: agent.provider,
                    engine: agent.engine,
                    state: agent.state,
                    task: agent.task,
                    updatedAt: monitorTimestamp(agent.updatedAt),
                    source: agent.source
                )
            }
        )
    }
}

/// `contracts/pet/v1/pet-actions.schema.json` envelope.
struct PetActionsEnvelope: Encodable, Equatable, Sendable {
    struct Action: Encodable, Equatable, Sendable {
        let id: String
        let parentId: String?
        let action: PetPresentationAction
    }

    let contract: String
    let version: String
    let generatedAt: String
    let producer: String
    let sequence: Int
    let actions: [Action]

    static func make(
        projection: PetActivityProjection,
        sequence: Int,
        producer: String = "lynk-monitor",
        generatedAt: Date = Date()
    ) -> PetActionsEnvelope {
        PetActionsEnvelope(
            contract: "pet-actions",
            version: "1.0.0",
            generatedAt: monitorTimestamp(generatedAt),
            producer: producer,
            sequence: sequence,
            actions: projection.agents.map { Action(id: $0.id, parentId: $0.parentId, action: $0.action) }
        )
    }
}

/// The Pet renderer is output-only: it must never receive Gateway control
/// tokens, Monitor auth, session prompts, or the app's own environment.
/// Only a small, benign OS allowlist plus the two contract file paths are
/// passed to the child process.
enum PetChildEnvironment {
    static let allowlistedKeys: Set<String> = ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SHELL"]

    static func make(from source: [String: String], stateFilePath: String, actionsFilePath: String) -> [String: String] {
        var result = source.filter { allowlistedKeys.contains($0.key) }
        result["PET_STATE_FILE"] = stateFilePath
        result["PET_ACTIONS_FILE"] = actionsFilePath
        return result
    }
}

/// One canonical timeline event (contracts/monitor/v2 `event`). The sidecar
/// gives every source — Gateway, Claude/Codex/Grok transcripts, agent hooks —
/// this one shape, and has already done the work the app used to guess at:
/// streamed chunks arrive merged into one `agent_message`/`agent_thought`, a
/// tool call and its updates are one `tool_call` whose `status` moves from
/// pending/running to completed/failed, and `title`/`body` are the display
/// text. Nothing here inspects a provider's raw payload.
struct MonitorEvent: Identifiable, Equatable, Sendable {
    /// `<sessionId>#<key>`: stable across re-reads and sidecar restarts, so an
    /// SSE `events` frame replaces the event it names instead of adding one.
    let id: String
    let key: String
    let sessionId: String
    /// Monitor-assigned, monotonic per session in first-seen order.
    let sequence: Int?
    let kind: String
    let timestamp: String?
    let endedAt: String?
    let turnId: String?
    let toolCallId: String?
    /// One-line summary (a tool's "Bash: ls -la", a prompt's first line).
    let title: String?
    /// Display text: the message, the thought, a tool's output.
    let body: String?
    /// pending, running, completed, failed, cancelled, or nil.
    let status: String?
    let sources: [String]
    /// Kind-specific extras (tool name/input, durationMs, requestId, …).
    let detail: [String: JSONValue]
    let payload: JSONValue

    /// Identity and display fields only. `payload` is the raw JSON these were
    /// read from; deep-comparing it on every upsert and state diff was the
    /// dominant cost of a busy stream, and nothing on screen reads it except
    /// the raw-JSON disclosure.
    static func == (lhs: MonitorEvent, rhs: MonitorEvent) -> Bool {
        lhs.id == rhs.id
            && lhs.sequence == rhs.sequence
            && lhs.kind == rhs.kind
            && lhs.status == rhs.status
            && lhs.timestamp == rhs.timestamp
            && lhs.endedAt == rhs.endedAt
            && lhs.turnId == rhs.turnId
            && lhs.toolCallId == rhs.toolCallId
            && lhs.title == rhs.title
            && lhs.body == rhs.body
            && lhs.sources == rhs.sources
            && lhs.detail == rhs.detail
    }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let sessionId = object.string("sessionId"),
              let kind = object.string("kind") else { return nil }
        let key = object.string("key")
        guard let id = object.string("id") ?? key.map({ "\(sessionId)#\($0)" }) else { return nil }
        self.id = id
        self.key = key ?? id
        self.sessionId = sessionId
        self.kind = kind
        sequence = object.int("sequence")
        timestamp = object.string("ts")
        endedAt = object.string("endedAt")
        turnId = object.string("turnId")
        toolCallId = object.string("toolCallId")
        title = nonEmptyText(object.string("title"))
        body = nonEmptyText(object.string("body"))
        status = object.string("status")
        sources = (object.array("sources") ?? []).compactMap(\.stringValue)
        detail = object.object("detail") ?? [:]
        payload = value
    }

    /// Short Korean label for the kind, as rows and nodes print it.
    var kindLabel: String { eventKindLabel(kind) }

    /// How the event stands, in one word: a request's outcome wins over the
    /// generic status, so a denied permission never reads "완료".
    var stateLabel: String? { requestStateLabel ?? eventStatusLabel(status) }

    /// Arrived through a CLI hook as it happened, not only from a transcript.
    var isHookObserved: Bool { sources.contains("hook") }

    /// The one line a timeline row or sequence node leads with. A tool call
    /// is named by its own compact header ("Bash: ls -la"), a permission or
    /// input request by how it stands, anything else by its kind.
    var headline: String {
        switch kind {
        case "tool_call": return compactToolTitle()
        case "permission_request", "input_request": return requestStateLabel ?? kindLabel
        default: return kindLabel
        }
    }

    /// A tool call's name and the head of its argument, cut to `limit`
    /// characters. The sidecar's title already reads "Bash: ls -la"; without
    /// one the tool name from `detail` stands in.
    func compactToolTitle(limit: Int = 30) -> String {
        let raw = title
            ?? detail["toolName"]?.stringValue
            ?? detail["name"]?.stringValue
            ?? kindLabel
        return oneLineText(raw, limit: limit)
    }

    /// How a permission / input request stands: waiting, approved, denied or
    /// cancelled. `detail.outcome` is the sidecar's verdict; the status is the
    /// fallback for a source that reports none. nil for other kinds.
    var requestStateLabel: String? {
        switch kind {
        case "permission_request":
            switch detail["outcome"]?.stringValue {
            case "approved": return "승인됨"
            case "denied": return "거부됨"
            case "cancelled": return "취소됨"
            default: break
            }
            switch status {
            case "pending", "running", nil: return "권한 요청 대기"
            // A response without a known outcome (an older source) is only
            // known to have been answered, not allowed.
            case "completed": return detail["outcome"] == nil ? "응답됨" : "승인됨"
            case "failed": return "거부됨"
            case "cancelled": return "취소됨"
            default: return "권한 요청"
            }
        case "input_request":
            switch status {
            case "pending", "running", nil: return "입력 요청 대기"
            case "completed": return "응답됨"
            case "failed": return "입력 실패"
            case "cancelled": return "취소됨"
            default: return "입력 요청"
            }
        default:
            return nil
        }
    }

    /// One line for a list row or tooltip: the sidecar's title, else the head
    /// of the body, else the kind.
    var summary: String {
        if let title { return title }
        if let body { return oneLineText(body, limit: 140, ellipsis: false) }
        return kindLabel
    }

    /// Still in flight: a tool call or request that has not finished.
    var isInFlight: Bool { status == "pending" || status == "running" }
    var isFailed: Bool { status == "failed" }
}

/// Korean label for a canonical event kind; an unknown kind reads as words.
func eventKindLabel(_ kind: String) -> String {
    switch kind {
    case "turn_start": "턴 시작"
    case "turn_end": "턴 종료"
    case "session_start": "세션 시작"
    case "session_end": "세션 종료"
    case "user_message": "사용자 입력"
    case "agent_message": "응답"
    case "agent_thought": "생각"
    case "tool_call": "도구 호출"
    case "permission_request": "권한 요청"
    case "input_request": "입력 요청"
    case "subagent": "서브에이전트"
    case "plan": "계획"
    case "compaction": "컨텍스트 압축"
    case "error": "오류"
    // An unlisted kind is not shown as raw text (docs/ux-policy.md §5).
    default: "알 수 없는 이벤트"
    }
}

/// Human word for an event (tool call, request) status, nil when the event
/// carries none.
func eventStatusLabel(_ status: String?) -> String? {
    switch status {
    case "pending": "시작 전"
    case "running": "실행 중"
    case "completed": "완료"
    case "failed": "실패"
    case "cancelled": "취소됨"
    default: nil
    }
}

/// A provider's display name; an unknown one never reads "Agent".
func providerDisplayLabel(_ provider: String) -> String {
    switch provider.lowercased() {
    case "claude": "Claude"
    case "codex": "Codex"
    case "grok": "Grok"
    case "", "unknown": "알 수 없는 CLI"
    default: provider.capitalized
    }
}

/// A CLI's product name where the user installs or configures it
/// (onboarding, agent catalog, hook consent, monitoring settings): the one
/// map every setup surface reads, so none spells a CLI differently.
func cliProductName(_ provider: String) -> String {
    switch provider.lowercased() {
    case "claude": "Claude Code"
    case "codex": "Codex"
    case "grok": "Grok"
    default: providerDisplayLabel(provider)
    }
}

/// "세션 목록을", "인스펙터를": the object particle that fits the word's last
/// syllable (a final consonant takes 을).
func withObjectParticle(_ word: String) -> String {
    guard let scalar = word.unicodeScalars.last else { return word }
    let value = scalar.value
    if (0xAC00...0xD7A3).contains(value) {
        return word + ((value - 0xAC00) % 28 == 0 ? "를" : "을")
    }
    return word + "을(를)"
}

/// The headline of "what the selected session is doing" (docs/ux-policy.md
/// §3): waiting first, then what the newest event of a running session is,
/// then the resting state.
func sessionActivityHeadline(status: String, isActive: Bool, latestKind: String?) -> String {
    switch status {
    case "waiting_permission": return "권한 대기 중"
    case "waiting_input": return "입력 대기 중"
    // Stopping, not working: never "실행 중".
    case "cancelling": return "취소 중"
    default: break
    }
    if isActive {
        switch latestKind {
        case "agent_thought": return "생각 중"
        case "agent_message": return "응답 생성 중"
        default: return "실행 중"
        }
    }
    switch status {
    case "idle", "ready", "end_turn", "completed": return "대기 · 다음 입력을 기다림"
    case "closed": return "종료됨"
    case "error", "failed": return "오류"
    default: return sessionStatusLabel(status)
    }
}

/// Whether a session is shown from history, not the live snapshot: the one
/// opened from "지난 기록", or any session no longer in the snapshot.
func isHistorySession(_ sessionId: String, liveSessionIds: Set<String>, openedHistoryId: String?) -> Bool {
    sessionId == openedHistoryId || !liveSessionIds.contains(sessionId)
}

/// A title that is a CLI's transient tool call or event path rather than a
/// name: "custom_tool_call/exec", "function_call", "hook/PreToolUse". A
/// sentence that merely mentions a path ("fix src/a.swift") is still a name.
func isToolishTitle(_ title: String) -> Bool {
    let lower = title.lowercased()
    if lower.contains("tool_call") || lower.contains("function_call") { return true }
    return title.contains("/") && !title.contains(where: \.isWhitespace)
}

/// Korean word for a session (or record) status — the same wording the
/// dashboard uses, so no header ever prints a raw `waiting_permission`.
func sessionStatusLabel(_ status: String) -> String {
    switch status {
    case "running": "실행 중"
    case "waiting_permission": "권한 대기"
    case "waiting_input": "입력 대기"
    // A finished turn is a resting session, not "완료" (docs/ux-policy.md §3).
    case "idle", "ready", "end_turn", "completed": "대기"
    case "closed": "종료"
    case "error": "오류"
    case "failed": "실패"
    case "disconnected": "연결 끊김"
    case "unavailable": "사용 불가"
    case "cancelling": "취소 중"
    case "cancelled": "취소됨"
    case "restoring": "복원 중"
    case "pending": "대기 중"
    case "interrupted": "중단됨"
    // An unlisted status is not shown as raw text (docs/ux-policy.md §3).
    default: "알 수 없음"
    }
}

/// A task / inbox record's status: like a session's, except that a finished
/// record is done ("완료"), not resting.
func recordStatusLabel(_ status: String) -> String {
    status == "completed" ? "완료" : sessionStatusLabel(status)
}

private func nonEmptyText(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}

/// One entry of the app's notice/error log: repeated identical errors fold
/// into a count so a flapping subscription reads as one line, not fifty.
struct NoticeEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let at: Date
    let text: String
    let count: Int

    init(at: Date, text: String, count: Int) {
        self.at = at
        self.text = text
        self.count = count
    }

    /// Newest-first insert: a consecutive duplicate bumps `count` on the
    /// first row; any other text becomes a new first row, capped at 50.
    static func record(_ text: String, at date: Date, into log: inout [NoticeEntry]) {
        if let last = log.first, last.text == text {
            log[0] = NoticeEntry(at: date, text: text, count: last.count + 1)
        } else {
            log.insert(NoticeEntry(at: date, text: text, count: 1), at: 0)
            if log.count > 50 { log.removeLast(log.count - 50) }
        }
    }
}

struct MonitorRecord: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let status: String?
    let title: String
    let subtitle: String
    let payload: JSONValue

    init(_ value: JSONValue, fallbackKind: String, index: Int) {
        let object = value.objectValue ?? [:]
        kind = object.string("type") ?? fallbackKind
        status = object.string("status")
        id = object.string("taskId") ?? object.string("inboxId") ?? "\(fallbackKind)-\(index)"
        title = object.string("statusMessage")
            ?? object.object("toolCall")?.string("title")
            ?? object.string("message")
            ?? kind.replacingOccurrences(of: "_", with: " ")
        subtitle = object.string("sessionId") ?? id
        payload = value
    }
}

/// A parsed `monitorApiVersion` string such as `"2.0"`. Minor is additive
/// (new optional capabilities); only a major mismatch is incompatible.
struct MonitorApiVersion: Equatable, Sendable {
    let major: Int
    let minor: Int

    init?(_ raw: String) {
        let parts = raw.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0 else { return nil }
        self.major = major
        self.minor = minor
    }
}

/// Validates the wire-contract version fields shared by `monitor_ready`,
/// `/api/meta`, `/api/snapshot`, and every SSE envelope. Unknown additive
/// fields are always compatible; a missing or unsupported schema/API major
/// must reject up front rather than let callers partially decode a message
/// they don't understand.
enum MonitorCompatibility {
    static let supportedSchemaVersion = 2
    static let supportedApiMajor = 2

    /// A missing/malformed version field means the message isn't even a
    /// message this build understands the shape of (`monitor_api_incompatible`);
    /// a well-formed field naming an unsupported major means the shape is
    /// understood but this build is simply too old (`monitor_update_required`).
    static func validate(_ object: [String: JSONValue]) throws {
        guard let schemaVersion = object.int("schemaVersion") else {
            throw MonitorDecodeError.apiIncompatible("Monitor 응답에 schemaVersion이 없거나 형식이 올바르지 않습니다.")
        }
        guard schemaVersion == supportedSchemaVersion else {
            throw MonitorDecodeError.updateRequired("Monitor schema version이 호환되지 않습니다. 앱을 업데이트하세요.")
        }
        guard let rawApiVersion = object.string("monitorApiVersion") else {
            throw MonitorDecodeError.apiIncompatible("Monitor 응답에 monitorApiVersion이 없습니다.")
        }
        guard let apiVersion = MonitorApiVersion(rawApiVersion) else {
            throw MonitorDecodeError.apiIncompatible("Monitor API version 형식이 올바르지 않습니다: \(rawApiVersion)")
        }
        guard apiVersion.major == supportedApiMajor else {
            throw MonitorDecodeError.updateRequired("Monitor API version이 호환되지 않습니다. 앱을 업데이트하세요.")
        }
    }
}

/// Gateway setup identity as surfaced by `monitor_ready`/`/api/meta`. Missing
/// Gateway setup values decode as `nil` rather than failing the handshake.
struct GatewayIdentity: Equatable, Sendable {
    let rootId: String?
    let gatewayApiVersion: Int?
    let gatewayVersion: String?
    let gatewayBuildId: String?

    init(_ value: JSONValue) {
        let object = value.objectValue ?? [:]
        rootId = object.string("rootId")
        gatewayApiVersion = object.int("gatewayApiVersion")
        gatewayVersion = object.string("gatewayVersion")
        gatewayBuildId = object.string("gatewayBuildId")
    }
}

/// Version/compatibility metadata shared by `monitor_ready` and `/api/meta`.
/// Deliberately excludes `apiToken` so it can be retained and passed around
/// without exposing the control secret.
struct MonitorMeta: Equatable, Sendable {
    let schemaVersion: Int
    let monitorApiVersion: String
    let sidecarVersion: String
    let sidecarBuildId: String
    let gatewayIdentity: GatewayIdentity
    let capabilities: JSONValue

    init(_ object: [String: JSONValue]) {
        schemaVersion = object.int("schemaVersion") ?? MonitorCompatibility.supportedSchemaVersion
        monitorApiVersion = object.string("monitorApiVersion") ?? ""
        sidecarVersion = object.string("sidecarVersion") ?? ""
        sidecarBuildId = object.string("sidecarBuildId") ?? ""
        gatewayIdentity = GatewayIdentity(object["gatewayIdentity"] ?? .null)
        capabilities = object["capabilities"] ?? .object([:])
    }

    static func decode(_ data: Data) throws -> MonitorMeta {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        try MonitorCompatibility.validate(root)
        return MonitorMeta(root)
    }
}

/// Which agents already have a Control MCP installed, per `/api/frontdoors`.
/// `primary` is the one installed as the exclusive `--install-all` Frontdoor
/// (nil when none is), and `installed` lists every agent — primary included —
/// that carries a Control MCP. Unversioned: the endpoint is a plain install
/// snapshot, so a missing/malformed body decodes to "nothing installed"
/// rather than failing the whole Settings load.
struct InstalledFrontdoors: Equatable, Sendable {
    let primary: String?
    let installed: [String]

    static func decode(_ data: Data) throws -> InstalledFrontdoors {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        return InstalledFrontdoors(
            primary: root.string("primary"),
            installed: (root.array("installed") ?? []).compactMap { $0.stringValue }
        )
    }
}

enum MonitorReducerDefaults {
    /// Matches the sidecar's default `maxEventsPerSession`.
    static let eventLimit = 2_000
    /// Older events paged in per session. Past it the oldest paged events
    /// fall off, so scrolling far up a long session stays bounded.
    static let pagedEventLimit = 5_000
    /// History sessions whose events stay loaded besides the open one.
    static let browsedSessionLimit = 5
    /// Rows of "지난 기록" kept in memory.
    static let browsedHistoryLimit = 500
}

/// Recently used keys, oldest first, at most `capacity` besides the pinned
/// one (the history session on screen, which never drops).
struct RecentKeys: Equatable, Sendable {
    let capacity: Int
    private(set) var keys: [String] = []

    init(capacity: Int) { self.capacity = max(0, capacity) }

    /// Marks `key` as just used; returns the keys that fell off.
    @discardableResult
    mutating func touch(_ key: String, pinned: String?) -> [String] {
        keys.removeAll { $0 == key }
        keys.append(key)
        var evicted: [String] = []
        while keys.filter({ $0 != pinned }).count > capacity,
              let oldest = keys.firstIndex(where: { $0 != pinned }) {
            evicted.append(keys.remove(at: oldest))
        }
        return evicted
    }

    mutating func remove(_ key: String) { keys.removeAll { $0 == key } }
    mutating func removeAll() { keys.removeAll() }
}

struct MonitorSnapshot: Sendable {
    let schemaVersion: Int
    let monitorApiVersion: String
    /// The monitor's session/event/tasks/inbox revision (additive; nil from an
    /// older monitor). Unchanged revision means the expensive session/event
    /// comparisons can be skipped wholesale on reconciliation.
    let revision: Int?
    let connected: Bool
    let streaming: Bool
    let error: String?
    let gateway: JSONValue?
    let sessions: [GatewaySession]
    let eventsBySession: [String: [MonitorEvent]]
    let historySessions: [GatewaySession]
    let historyEventsBySession: [String: [MonitorEvent]]
    /// The sidecar's per-session event cap; upserts trim to the same bound.
    let eventLimit: Int
    let tasks: [MonitorRecord]
    let inbox: [MonitorRecord]

    static func decode(_ data: Data) throws -> MonitorSnapshot {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidRoot }
        try MonitorCompatibility.validate(root)
        let sessions = (root.array("sessions") ?? []).compactMap(GatewaySession.init)
        var eventsBySession: [String: [MonitorEvent]] = [:]
        for (sessionId, value) in root.object("events") ?? [:] {
            eventsBySession[sessionId] = (value.arrayValue ?? []).compactMap(MonitorEvent.init).sorted(by: withinSessionEventOrder)
        }
        let historySessions = (root.array("historySessions") ?? []).compactMap(GatewaySession.init)
        var historyEventsBySession: [String: [MonitorEvent]] = [:]
        for (sessionId, value) in root.object("historyEvents") ?? [:] {
            historyEventsBySession[sessionId] = (value.arrayValue ?? []).compactMap(MonitorEvent.init).sorted(by: withinSessionEventOrder)
        }
        let tasks = (root.array("tasks") ?? []).enumerated().map { MonitorRecord($0.element, fallbackKind: "task", index: $0.offset) }
        let inbox = (root.array("inbox") ?? []).enumerated().map { MonitorRecord($0.element, fallbackKind: "inbox", index: $0.offset) }
        return MonitorSnapshot(
            schemaVersion: root.int("schemaVersion") ?? MonitorCompatibility.supportedSchemaVersion,
            monitorApiVersion: root.string("monitorApiVersion") ?? "",
            revision: root.int("revision"),
            connected: root.bool("connected") ?? false,
            streaming: root.bool("streaming") ?? root.bool("connected") ?? false,
            error: root.string("error"),
            gateway: root["gateway"],
            sessions: sessions,
            eventsBySession: eventsBySession,
            historySessions: historySessions,
            historyEventsBySession: historyEventsBySession,
            eventLimit: max(root.int("eventLimit") ?? MonitorReducerDefaults.eventLimit, 1),
            tasks: tasks,
            inbox: inbox
        )
    }
}

struct ACPAgentCatalogItem: Identifiable, Equatable, Sendable {
    let registryId: String
    let providerId: String
    let name: String
    /// The version the ACP registry currently offers.
    let version: String
    /// The version this Mac has configured (from providers.json), or nil when
    /// nothing is installed. Compared against `version` to offer an update.
    let installedVersion: String?
    let description: String
    let website: URL?
    let icon: URL?
    let distribution: String
    let compatible: Bool
    let installed: Bool
    let enabled: Bool
    let installSupported: Bool
    let installHint: String

    var id: String { registryId }

    /// An installed adapter whose configured version differs from the
    /// registry's current one. Re-installing pulls the newer version, so this
    /// drives the per-row "업데이트" action. A not-installed adapter is never
    /// "outdated" — it is simply not present.
    var updateAvailable: Bool {
        guard installed, let installedVersion, !installedVersion.isEmpty else { return false }
        return installedVersion != version
    }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let registryId = object.string("registryId"),
              let providerId = object.string("providerId") else { return nil }
        self.registryId = registryId
        self.providerId = providerId
        name = object.string("name") ?? registryId
        version = object.string("version") ?? "—"
        installedVersion = object.string("installedVersion")
        description = object.string("description") ?? ""
        website = object.string("website").flatMap(URL.init(string:))
        icon = object.string("icon").flatMap(URL.init(string:))
        distribution = object.string("distribution") ?? "unsupported"
        compatible = object.bool("compatible") ?? false
        installed = object.bool("installed") ?? false
        enabled = object.bool("enabled") ?? false
        installSupported = object.bool("installSupported") ?? false
        installHint = object.string("installHint") ?? ""
    }
}

struct ACPAgentCatalogSnapshot: Sendable {
    let registryVersion: String
    let source: String
    let stale: Bool
    let warning: String?
    let agents: [ACPAgentCatalogItem]

    static func decode(_ data: Data) throws -> ACPAgentCatalogSnapshot {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        return ACPAgentCatalogSnapshot(
            registryVersion: root.string("registryVersion") ?? "—",
            source: root.string("source") ?? "unknown",
            stale: root.bool("stale") ?? false,
            warning: root.string("warning"),
            agents: (root.array("agents") ?? []).compactMap(ACPAgentCatalogItem.init)
        )
    }
}

/// One CLI's monitoring-hook registration, as GET /api/hooks reports it.
struct MonitoringHookTarget: Identifiable, Equatable, Sendable {
    let provider: String
    let agentPresent: Bool
    let disabled: Bool
    let installed: Bool
    let partial: Bool
    let needsTrust: Bool
    let error: String?
    let file: String

    var id: String { provider }

    init?(provider: String, _ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        self.provider = provider
        agentPresent = object.bool("agentPresent") ?? false
        disabled = object.bool("disabled") ?? false
        installed = object.bool("installed") ?? false
        partial = object.bool("partial") ?? false
        needsTrust = object.bool("needsTrust") ?? false
        error = object.string("error")
        file = object.string("file") ?? ""
    }
}

/// The monitoring hooks AgenLynk registers in Claude Code, Codex and Grok.
struct MonitoringHookStatus: Equatable, Sendable {
    /// The running sidecar accepts hook events (only the app's own does).
    let receiving: Bool
    let enabled: Bool
    /// Nothing has been installed yet because the user has not been asked.
    let consentRequired: Bool
    let targets: [MonitoringHookTarget]
    let errors: [String]
    /// provider → when this sidecar last received one of its hooks. Missing
    /// means none has arrived since the sidecar started.
    var lastReceivedAt: [String: Date] = [:]

    /// The settings row's state text for one CLI.
    func stateText(for target: MonitoringHookTarget, now: Date = Date()) -> String {
        if !target.agentPresent { return "설치된 CLI 없음" }
        if target.error != nil { return "설정 파일 오류" }
        if target.needsTrust { return "승인 필요" }
        if target.installed {
            guard let last = lastReceivedAt[target.provider] else { return "등록됨 · 아직 수신 없음" }
            return "등록됨 · 마지막 수신 \(relativeTimeText(from: last, to: now))"
        }
        if target.partial { return "일부만 등록됨" }
        return "꺼짐"
    }

    static let providerOrder = ["claude", "codex", "grok"]

    static func decode(_ data: Data) throws -> MonitoringHookStatus {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        let targets = root.object("targets") ?? [:]
        return MonitoringHookStatus(
            receiving: root.bool("receiving") ?? false,
            enabled: root.bool("enabled") ?? true,
            consentRequired: root.bool("consentRequired") ?? false,
            targets: providerOrder.compactMap { provider in targets[provider].flatMap { MonitoringHookTarget(provider: provider, $0) } },
            errors: (root.object("errors") ?? [:]).values.compactMap(\.stringValue),
            lastReceivedAt: (root.object("lastReceivedAt") ?? [:]).reduce(into: [String: Date]()) { result, item in
                if let text = item.value.stringValue, let date = parseTimestamp(text) { result[item.key] = date }
            }
        )
    }
}

/// GET /api/history/stats (and the body of POST /api/history clear): the
/// on-disk monitor history. `available` is false when disk history is off
/// (retention 0) or the database could not be opened.
struct MonitorHistoryStats: Equatable, Sendable {
    let available: Bool
    let path: String?
    let bytes: Double?
    let sessions: Int?
    let events: Int?
    let retentionDays: Double?
    /// Sessions a clear removed; only on the clear response.
    let deleted: Int?

    /// Retention 0 keeps nothing on disk.
    var diskHistoryOff: Bool { (retentionDays ?? 1) <= 0 }

    var retentionText: String? {
        guard let retentionDays else { return nil }
        if retentionDays <= 0 { return "보관 안 함" }
        if retentionDays < 1 { return "\(max(1, Int((retentionDays * 24).rounded())))시간" }
        return "\(Int(retentionDays.rounded()))일"
    }

    static func decode(_ data: Data) throws -> MonitorHistoryStats {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        return MonitorHistoryStats(
            available: root.bool("available") ?? false,
            path: root.string("path"),
            bytes: root.double("bytes"),
            sessions: root.int("sessions"),
            events: root.int("events"),
            retentionDays: root.double("retentionDays"),
            deleted: root.int("deleted")
        )
    }
}

/// GET /api/history: persisted session records, newest first.
struct MonitorHistoryPage: Equatable, Sendable {
    let sessions: [GatewaySession]
    let hasMore: Bool

    static func decode(_ data: Data) throws -> MonitorHistoryPage {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        let sessions = (root.array("sessions") ?? []).compactMap(GatewaySession.init)
        return MonitorHistoryPage(sessions: sessions, hasMore: root.bool("hasMore") ?? false)
    }
}

/// GET /api/sessions/:id/events: one page of a session's older events,
/// oldest first. Events naming another session are dropped.
struct SessionEventsPage: Equatable, Sendable {
    let sessionId: String
    let events: [MonitorEvent]

    static func decode(_ data: Data, sessionId: String) throws -> SessionEventsPage {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        let id = root.string("sessionId") ?? sessionId
        guard id == sessionId else { throw MonitorDecodeError.invalidMessage }
        let events = (root.array("events") ?? []).compactMap(MonitorEvent.init)
            .filter { $0.sessionId == sessionId }
            .sorted(by: withinSessionEventOrder)
        return SessionEventsPage(sessionId: sessionId, events: events)
    }
}

/// One installed Gateway runtime, as `runtime-updater.js` reports it.
struct RuntimeVersionSummary: Identifiable, Equatable, Sendable {
    let versionId: String
    let runtimeRoot: String
    let isCurrent: Bool
    let isPrevious: Bool
    let gatewayVersion: String?
    let gatewayBuildId: String?
    let gatewayApiVersion: Int?
    let apiCompatible: Bool?
    let nodeVersion: String?
    /// Present when the version's manifest could not be read at all.
    let manifestError: String?

    var id: String { versionId }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let versionId = object.string("versionId") else { return nil }
        self.versionId = versionId
        runtimeRoot = object.string("runtimeRoot") ?? ""
        isCurrent = object.bool("isCurrent") ?? false
        isPrevious = object.bool("isPrevious") ?? false
        gatewayVersion = object.string("gatewayVersion")
        gatewayBuildId = object.string("gatewayBuildId")
        gatewayApiVersion = object.int("gatewayApiVersion")
        apiCompatible = object.bool("apiCompatible")
        nodeVersion = object.string("nodeVersion")
        manifestError = object.string("manifestError")
    }
}

/// The updater's `inspect` result: what is installed and which one is live.
struct RuntimeInspection: Equatable, Sendable {
    let runtimeRoot: String
    let currentVersionId: String?
    let currentGatewayVersion: String?
    let currentGatewayBuildId: String?
    let previousVersionId: String?
    /// The user rolled back to this runtime, so app updates deliberately stop
    /// replacing it. Without showing this the machine just looks stuck on an
    /// old build. Picking a version in the updater clears it.
    let currentPinned: Bool
    let versions: [RuntimeVersionSummary]

    var current: RuntimeVersionSummary? { versions.first(where: \.isCurrent) }
    var previous: RuntimeVersionSummary? { versions.first(where: \.isPrevious) }
    var canRollback: Bool { previous != nil }
    var pinnedNotice: String? {
        guard currentPinned else { return nil }
        return "이 버전으로 되돌려 고정되어 있습니다. 앱을 업데이트해도 런타임은 바뀌지 않습니다. 아래 \"이 앱의 런타임 설치 및 적용\"으로 이 앱에 포함된 런타임을 설치하면 고정이 풀립니다."
    }

    init?(_ value: JSONValue) {
        guard let root = value.objectValue else { return nil }
        let current = root.object("current")
        runtimeRoot = root.string("runtimeRoot") ?? ""
        currentVersionId = current?.string("runtimeRoot").map { ($0 as NSString).lastPathComponent }
        currentGatewayVersion = current?.string("gatewayVersion")
        currentGatewayBuildId = current?.string("gatewayBuildId")
        previousVersionId = root.object("previous")?.string("runtimeRoot").map { ($0 as NSString).lastPathComponent }
        currentPinned = current?.bool("pinned") ?? false
        versions = (root.array("versions") ?? []).compactMap(RuntimeVersionSummary.init)
    }

    static func decode(_ data: Data) throws -> RuntimeInspection {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let inspection = RuntimeInspection(JSONValue(any: raw)) else {
            throw MonitorDecodeError.invalidMessage
        }
        return inspection
    }
}

/// A single updater operation's outcome. The library reports expected failures
/// inside the envelope, so an unsuccessful result is still a decoded value.
struct RuntimeOperationResult: Equatable, Sendable {
    let ok: Bool
    let op: String
    let versionId: String?
    let errorCode: String?
    let errorMessage: String?

    init(_ value: JSONValue) {
        let root = value.objectValue ?? [:]
        let error = root.object("error")
        ok = root.bool("ok") ?? false
        op = root.string("op") ?? ""
        versionId = root.string("versionId") ?? root.object("activated")?.string("versionId")
        errorCode = error?.string("code")
        errorMessage = error?.string("message")
    }

    static func decode(_ data: Data) throws -> RuntimeOperationResult {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard JSONValue(any: raw).objectValue != nil else { throw MonitorDecodeError.invalidMessage }
        return RuntimeOperationResult(JSONValue(any: raw))
    }
}

/// How many sessions/tasks/inbox records/artifacts a retention change would
/// delete. Counted by the Gateway without deleting anything, so the app can
/// ask before a destructive save.
struct RetentionPreview: Equatable, Sendable {
    let sessions: Int
    let tasks: Int
    let inbox: Int
    let artifacts: Int

    var isEmpty: Bool { sessions == 0 && tasks == 0 && inbox == 0 && artifacts == 0 }

    /// A human-readable list of only the non-zero counts.
    var summary: String {
        var parts: [String] = []
        if sessions > 0 { parts.append("세션 \(sessions)개") }
        if tasks > 0 { parts.append("태스크 \(tasks)개") }
        if inbox > 0 { parts.append("요청 \(inbox)개") }
        if artifacts > 0 { parts.append("첨부 파일 \(artifacts)개") }
        return parts.joined(separator: ", ")
    }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        sessions = object.int("sessions") ?? 0
        tasks = object.int("tasks") ?? 0
        inbox = object.int("inbox") ?? 0
        artifacts = object.int("artifacts") ?? 0
    }

    init(sessions: Int, tasks: Int, inbox: Int, artifacts: Int) {
        self.sessions = sessions
        self.tasks = tasks
        self.inbox = inbox
        self.artifacts = artifacts
    }

    static func decode(_ data: Data) throws -> RetentionPreview {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let preview = RetentionPreview(JSONValue(any: raw)) else {
            throw MonitorDecodeError.invalidMessage
        }
        return preview
    }
}

/// Display scale the Gateway advertises for a millisecond setting. Storage,
/// validation, and the wire format stay in milliseconds — this only decides
/// what number the editor shows, so "7" can stand in for 604800000.
enum GatewayDisplayUnit: String, Equatable, Sendable {
    case days
    case hours
    case minutes
    case seconds

    var millisecondFactor: Int {
        switch self {
        case .days: 24 * 60 * 60 * 1_000
        case .hours: 60 * 60 * 1_000
        case .minutes: 60 * 1_000
        case .seconds: 1_000
        }
    }

    var suffix: String {
        switch self {
        case .days: "일"
        case .hours: "시간"
        case .minutes: "분"
        case .seconds: "초"
        }
    }
}

/// One value's presentation: divide the stored number by `factor` to show it,
/// multiply back to store it. `factor == 1` means the stored number is shown
/// as-is, which is also the exact fallback for values that do not divide
/// evenly into their display unit.
struct GatewayValueScale: Equatable, Sendable {
    let factor: Int
    let suffix: String

    var isScaled: Bool { factor > 1 }

    func display(_ stored: Int) -> Int { factor > 1 ? stored / factor : stored }

    /// Saturates instead of trapping: a user can type an absurd number of days
    /// into a text field, and that must not crash the settings window.
    func stored(_ display: Int) -> Int {
        guard factor > 1 else { return display }
        let (product, overflow) = display.multipliedReportingOverflow(by: factor)
        return overflow ? (display < 0 ? Int.min : Int.max) : product
    }
}

struct GatewayConfigOption: Identifiable, Equatable, Sendable {
    let id: String
    let group: String
    let type: String
    let label: String
    let labelKo: String
    let description: String
    let descriptionKo: String
    let unit: String?
    let displayUnit: GatewayDisplayUnit?
    let minimum: Int?
    let defaultValue: JSONValue
    let currentValue: JSONValue
    let configuredValue: JSONValue
    let storedValue: JSONValue?
    let source: String
    let environment: String
    let editable: Bool
    let requiresRestart: Bool
    let pending: Bool

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let id = object.string("id"),
              let group = object.string("group"),
              let type = object.string("type") else { return nil }
        self.id = id
        self.group = group
        self.type = type
        label = object.string("label") ?? id
        labelKo = object.string("labelKo") ?? label
        description = object.string("description") ?? ""
        descriptionKo = object.string("descriptionKo") ?? description
        unit = object.string("unit")
        displayUnit = object.string("displayUnit").flatMap(GatewayDisplayUnit.init(rawValue:))
        minimum = object.int("minimum")
        defaultValue = object["defaultValue"] ?? .null
        currentValue = object["currentValue"] ?? .null
        configuredValue = object["configuredValue"] ?? currentValue
        if let stored = object["storedValue"], stored != .null { storedValue = stored } else { storedValue = nil }
        source = object.string("source") ?? "default"
        environment = object.string("environment") ?? ""
        editable = object.bool("editable") ?? false
        requiresRestart = object.bool("requiresRestart") ?? true
        pending = object.bool("pending") ?? false
    }

    /// The scale to edit one concrete stored value in. A millisecond setting
    /// only uses its display unit when the value divides evenly, so every
    /// display → stored round-trip is exact; anything else (a legacy stored
    /// number, an environment override, a value clamped to a minimum that is
    /// not a whole unit) falls back to raw milliseconds rather than being
    /// rounded into a different value.
    func valueScale(for storedValue: Int) -> GatewayValueScale {
        guard let displayUnit, storedValue % displayUnit.millisecondFactor == 0 else {
            return GatewayValueScale(factor: 1, suffix: unit ?? "")
        }
        return GatewayValueScale(factor: displayUnit.millisecondFactor, suffix: displayUnit.suffix)
    }
}

struct GatewayConfigSnapshot: Sendable {
    let options: [GatewayConfigOption]
    let pendingRestart: Bool
    let pendingLiveApply: Bool

    static func decode(_ data: Data) throws -> GatewayConfigSnapshot {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        return GatewayConfigSnapshot(
            options: (root.array("options") ?? []).compactMap(GatewayConfigOption.init),
            pendingRestart: root.bool("pendingRestart") ?? false,
            pendingLiveApply: root.bool("pendingLiveApply") ?? false
        )
    }
}

/// A single selectable value inside a Worker-advertised `select` config
/// option. The Gateway accepts one level of nested choice groups (an
/// `options` array whose items may themselves carry a nested `options`
/// array); this is already flattened to leaves, with `groupName` set when a
/// leaf came from a nested group so the UI can still show that context.
struct SessionConfigOptionChoice: Identifiable, Equatable, Sendable {
    let value: String
    let name: String
    let groupName: String?

    var id: String { value }
}

/// A Worker-advertised per-session config option (ACP `session/config`).
/// Only `select` and `boolean` are understood; any other advertised type is
/// preserved as `.unknown(type)` so the UI can show it as a disabled,
/// informational row instead of dropping or crashing on it.
struct SessionConfigOption: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case select(choices: [SessionConfigOptionChoice])
        case boolean
        case unknown(String)
    }

    let id: String
    let name: String
    let category: String?
    let kind: Kind
    let currentValue: JSONValue

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let id = object.string("id"),
              let type = object.string("type") else { return nil }
        self.id = id
        name = object.string("name") ?? id
        category = object.string("category")
        currentValue = object["currentValue"] ?? .null
        switch type {
        case "boolean":
            kind = .boolean
        case "select":
            kind = .select(choices: Self.flattenChoices(object.array("options") ?? []))
        default:
            kind = .unknown(type)
        }
    }

    private static func flattenChoices(_ raw: [JSONValue]) -> [SessionConfigOptionChoice] {
        raw.flatMap { item -> [SessionConfigOptionChoice] in
            guard let object = item.objectValue else { return [] }
            if let nested = object.array("options") {
                let groupName = object.string("name")
                return nested.compactMap { leaf -> SessionConfigOptionChoice? in
                    guard let leafObject = leaf.objectValue, let value = leafObject.string("value") else { return nil }
                    return SessionConfigOptionChoice(value: value, name: leafObject.string("name") ?? value, groupName: groupName)
                }
            }
            guard let value = object.string("value") else { return [] }
            return [SessionConfigOptionChoice(value: value, name: object.string("name") ?? value, groupName: nil)]
        }
    }
}

struct SessionConfigSnapshot: Sendable {
    let sessionId: String
    let options: [SessionConfigOption]
    let unavailableReason: String?

    static func decode(_ data: Data) throws -> SessionConfigSnapshot {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidMessage }
        return SessionConfigSnapshot(
            sessionId: root.string("sessionId") ?? "",
            options: (root.array("configOptions") ?? []).compactMap(SessionConfigOption.init),
            unavailableReason: root.string("unavailableReason")
        )
    }
}

/// Local decode/compatibility failures. `stableCode` mirrors the same
/// `monitor_api_incompatible` / `monitor_update_required` wire vocabulary
/// `MonitorClientError.code` carries for server-originated failures, so both
/// error surfaces are testable against the identical stable-code contract:
/// malformed or missing version fields (`invalidRoot`, `invalidMessage`,
/// `apiIncompatible`) can never be decoded at all, while `updateRequired` is
/// a well-formed message this build is simply too old to understand.
enum MonitorDecodeError: LocalizedError {
    case invalidRoot
    case invalidMessage
    case apiIncompatible(String)
    case updateRequired(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "Monitor snapshot is not a JSON object."
        case .invalidMessage: "Monitor stream delivered an invalid message."
        case let .apiIncompatible(message): message
        case let .updateRequired(message): message
        }
    }

    var stableCode: String {
        switch self {
        case .invalidRoot, .invalidMessage, .apiIncompatible: "monitor_api_incompatible"
        case .updateRequired: "monitor_update_required"
        }
    }
}

/// A Node Monitor HTTP error response, `{error, code}`. `code` is a stable
/// identifier callers can branch on (auth failure, incompatible API,
/// restart blocked, ...); `error` stays the human-readable message. An
/// explicit server `code` (e.g. `monitor_unauthorized`, `monitor_restart_blocked`)
/// is always preserved verbatim, never inferred or overwritten.
enum MonitorClientError: LocalizedError, Equatable, Sendable {
    case server(code: String?, message: String)

    /// A body without a parseable `error`/`code` still decodes to a
    /// readable fallback instead of failing.
    static func decode(data: Data, statusCode: Int) -> MonitorClientError {
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = body?["error"] as? String ?? "Monitor request failed (HTTP \(statusCode))"
        return .server(code: body?["code"] as? String, message: message)
    }

    var code: String? {
        guard case let .server(code, _) = self else { return nil }
        return code
    }

    var errorDescription: String? {
        guard case let .server(_, message) = self else { return nil }
        return message
    }
}

// ── Canonical MonitorEvent orderings ─────────────────────────────────────
// Both follow the contract's "ts, then sequence" order. `ts` is when the fact
// was first observed, and a later observation of the same event (a tool call
// finishing) keeps it, so an upserted event never jumps position. `sequence`
// is the monitor's first-seen counter and only breaks timestamp ties.

/// Order WITHIN one session. The sidecar writes every `ts` in the same
/// fixed-width ISO8601 form, so string order is time order.
func withinSessionEventOrder(_ lhs: MonitorEvent, _ rhs: MonitorEvent) -> Bool {
    if lhs.timestamp != rhs.timestamp { return (lhs.timestamp ?? "") < (rhs.timestamp ?? "") }
    if lhs.sequence != rhs.sequence { return (lhs.sequence ?? Int.max) < (rhs.sequence ?? Int.max) }
    return lhs.id < rhs.id
}

/// Order ACROSS sessions: sequences are per-session counters, so wall-clock
/// order decides and the session id keeps equal timestamps deterministic.
func crossSessionEventOrder(_ lhs: MonitorEvent, _ rhs: MonitorEvent) -> Bool {
    if lhs.timestamp != rhs.timestamp { return (lhs.timestamp ?? "") < (rhs.timestamp ?? "") }
    if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
    return withinSessionEventOrder(lhs, rhs)
}

/// Upserts changed events into one session's bucket, the v2 rule for both SSE
/// `events` frames and a `state` frame's `events`: an event whose `id` is
/// already present replaces it in place, a new `id` is inserted, the bucket
/// stays in `withinSessionEventOrder`, and only the oldest events fall off
/// past `limit` (the sidecar's `eventLimit`). A later duplicate of one id in
/// the same batch wins.
func upsertMonitorEvents(_ changes: [MonitorEvent], into bucket: [MonitorEvent], limit: Int) -> [MonitorEvent] {
    var result = bucket
    upsertMonitorEvents(changes, into: &result, limit: limit)
    return result
}

/// In-place form of the upsert above; returns whether the bucket changed, so
/// callers never have to diff the whole bucket (or state) afterwards. The
/// bucket must already be in `withinSessionEventOrder` (every producer keeps
/// it so); only the neighbours of what changed are checked.
@discardableResult
func upsertMonitorEvents(_ changes: [MonitorEvent], into bucket: inout [MonitorEvent], limit: Int) -> Bool {
    guard !changes.isEmpty else { return false }
    var changed = false
    var touched: [Int] = []
    touched.reserveCapacity(changes.count)
    // A frame names a few events, almost always the newest: a backwards scan
    // finds them without hashing every id of the bucket. Large batches (a
    // page, a merge) index the bucket once instead.
    var indexById: [String: Int]?
    if changes.count > 16 {
        var index: [String: Int] = [:]
        index.reserveCapacity(bucket.count + changes.count)
        for (offset, event) in bucket.enumerated() { index[event.id] = offset }
        indexById = index
    }
    for event in changes {
        let existing = indexById.map { $0[event.id] } ?? bucket.lastIndex { $0.id == event.id }
        if let existing {
            guard bucket[existing] != event else { continue }
            bucket[existing] = event
            touched.append(existing)
        } else {
            indexById?[event.id] = bucket.count
            touched.append(bucket.count)
            bucket.append(event)
        }
        changed = true
    }
    guard changed else { return false }
    let outOfOrder = touched.contains { index in
        (index > 0 && withinSessionEventOrder(bucket[index], bucket[index - 1]))
            || (index + 1 < bucket.count && withinSessionEventOrder(bucket[index + 1], bucket[index]))
    }
    if outOfOrder { bucket.sort(by: withinSessionEventOrder) }
    if bucket.count > limit { bucket.removeFirst(bucket.count - limit) }
    return true
}

/// A warning when the running Gateway daemon serves from a different runtime
/// root than the monitor — the split-brain state the Node monitor annotates
/// onto its setup info. Left unsurfaced, the user keeps running old Gateway
/// code with no visible sign; a safe restart respawns from the monitor's
/// runtime and heals it.
func runtimeSplitWarning(gateway: JSONValue?) -> String? {
    guard let split = gateway?.objectValue?.object("runtimeSplit") else { return nil }
    if let daemonRoot = split.string("daemonRuntimeRoot") {
        return "실행 중인 Gateway가 다른 runtime(\(daemonRoot))에서 동작하고 있습니다. Gateway 구성에서 '적용 및 안전 재시작'을 실행하면 현재 runtime으로 전환됩니다."
    }
    if let daemonBuildId = split.string("daemonBuildId"),
       let monitorBuildId = split.string("monitorBuildId") {
        return "실행 중인 Gateway build(\(daemonBuildId))가 설치된 runtime build(\(monitorBuildId))와 다릅니다. Gateway 구성에서 '적용 및 안전 재시작'을 실행하면 현재 runtime으로 전환됩니다."
    }
    return nil
}

/// User-facing guidance per stable monitor failure code. The codes come from
/// both sides of the wire — the Node monitor's HTTP bodies and the Swift
/// client's own classification — and this is the single place that turns a
/// code into "what should the user actually do", so every surface (dashboard,
/// menu bar, settings) explains a failure the same way.
func monitorFailureGuidance(code: String?) -> String? {
    switch code {
    case "monitor_not_installed":
        "Gateway runtime이 설치되어 있지 않습니다. 설정 > 버전·업데이트에서 이 앱의 runtime을 설치하세요."
    case "monitor_api_incompatible":
        "설치된 Gateway runtime이 이 앱과 호환되지 않습니다. 설정 > 버전·업데이트에서 runtime을 업데이트하세요."
    case "monitor_update_required":
        "이 앱이 설치된 runtime보다 오래되었습니다. 새 버전의 Lynk로 업데이트하세요."
    case "monitor_unauthorized":
        "Monitor 인증이 유효하지 않습니다. '모니터 다시 연결'을 눌러 세션을 새로 만드세요."
    case "monitor_restart_blocked":
        "진행 중인 세션·태스크·미응답 요청이 끝나면 다시 시도하세요."
    default:
        nil
    }
}

/// Selection identity against the merged live+history log — the same lists
/// the sidebar and sequence view render. Live-only membership reassigned the
/// Frontdoor whenever it left the live set and cleared the picked event.
enum MonitorSelection {
    struct Result: Equatable, Sendable {
        var frontdoorId: String?
        var eventId: String?
    }

    static func reconcile(
        selectedFrontdoorId: String?,
        selectedEventId: String?,
        liveSessions: [GatewaySession],
        historySessions: [GatewaySession],
        liveEvents: [String: [MonitorEvent]],
        historyEvents: [String: [MonitorEvent]]
    ) -> Result {
        var sessionsById: [String: GatewaySession] = [:]
        for session in historySessions { sessionsById[session.sessionId] = session }
        for session in liveSessions { sessionsById[session.sessionId] = session }
        return reconcile(
            selectedFrontdoorId: selectedFrontdoorId,
            selectedEventId: selectedEventId,
            frontdoors: FrontdoorSession.make(sessions: sessionsById.values.filter { !$0.isInternalReview }),
            liveEvents: liveEvents,
            historyEvents: historyEvents
        )
    }

    /// The same, against Frontdoors the caller already built (the app keeps
    /// them cached per log revision).
    static func reconcile(
        selectedFrontdoorId: String?,
        selectedEventId: String?,
        frontdoors available: [FrontdoorSession],
        liveEvents: [String: [MonitorEvent]],
        historyEvents: [String: [MonitorEvent]]
    ) -> Result {
        let frontdoorId: String?
        if let selectedFrontdoorId, available.contains(where: { $0.id == selectedFrontdoorId }) {
            frontdoorId = selectedFrontdoorId
        } else {
            frontdoorId = available.first(where: \.isActive)?.id ?? available.first?.id
        }

        let eventId = selectedEventId.flatMap { id in
            contains(id, in: historyEvents) || contains(id, in: liveEvents) ? id : nil
        }
        return Result(frontdoorId: frontdoorId, eventId: eventId)
    }

    /// Event ids are `<sessionId>#<key>`, so only the bucket of that session
    /// is searched — not an index of every retained event for one id. An id
    /// of another shape (no bucket matches a prefix) falls back to a scan.
    static func contains(_ eventId: String, in buckets: [String: [MonitorEvent]]) -> Bool {
        var matchedBucket = false
        var cursor = eventId.startIndex
        while let hash = eventId[cursor...].firstIndex(of: "#") {
            if let bucket = buckets[String(eventId[..<hash])] {
                matchedBucket = true
                if bucket.contains(where: { $0.id == eventId }) { return true }
            }
            cursor = eventId.index(after: hash)
        }
        guard !matchedBucket else { return false }
        return buckets.values.contains { bucket in bucket.contains { $0.id == eventId } }
    }
}

/// A connected Gateway whose event subscription paused records that error
/// as a notice. Overflow arrives as `kind: "state"`, not `kind: "notice"`.
enum MonitorStreamNotice {
    static func forPausedSubscription(connected: Bool, streaming: Bool?, error: String?) -> String? {
        guard connected, streaming == false, let error else { return nil }
        return error
    }
}

func decodeJSONValue(_ data: Data) throws -> JSONValue {
    JSONValue(any: try JSONSerialization.jsonObject(with: data))
}

// MARK: - Update surface (app / seed gateway / release feed)

/// One AgenLynk release resolved from the GitHub releases feed: the bare
/// version, a download target (the DMG asset, or the release page as a
/// fallback), and the release page itself.
struct AppReleaseInfo: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let htmlURL: URL?
}

/// The Gateway version+build the app bundle ships as its runtime seed, read
/// from Contents/Resources/gateway-seed/runtime-manifest.json. nil in a
/// source-tree/dev build that bundles no seed.
struct SeedGatewayVersion: Equatable, Sendable {
    let gatewayVersion: String
    let gatewayBuildId: String
}

/// Strips a leading `v`/`V` from a release tag: `"v0.3.4"` → `"0.3.4"`.
func parseReleaseVersion(_ tag: String) -> String {
    var trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
    return trimmed
}

/// Semantic-version precedence, including prereleases: numeric core components
/// compare numerically, a prerelease sorts below the matching stable version,
/// and prerelease identifiers follow SemVer numeric/lexical ordering. Build
/// metadata does not affect precedence.
func compareSemanticVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = semanticVersionComponents(lhs)
    let right = semanticVersionComponents(rhs)
    for index in 0..<max(left.core.count, right.core.count) {
        let a = index < left.core.count ? left.core[index] : 0
        let b = index < right.core.count ? right.core[index] : 0
        if a != b { return a < b ? .orderedAscending : .orderedDescending }
    }

    switch (left.prerelease, right.prerelease) {
    case (nil, nil):
        return .orderedSame
    case (.some, nil):
        return .orderedAscending
    case (nil, .some):
        return .orderedDescending
    case let (.some(leftIdentifiers), .some(rightIdentifiers)):
        for index in 0..<min(leftIdentifiers.count, rightIdentifiers.count) {
            let a = leftIdentifiers[index]
            let b = rightIdentifiers[index]
            if a == b { continue }
            switch (Int(a), Int(b)) {
            case let (.some(leftNumber), .some(rightNumber)):
                return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
            case (.some, nil):
                return .orderedAscending
            case (nil, .some):
                return .orderedDescending
            case (nil, nil):
                return a < b ? .orderedAscending : .orderedDescending
            }
        }
        if leftIdentifiers.count != rightIdentifiers.count {
            return leftIdentifiers.count < rightIdentifiers.count ? .orderedAscending : .orderedDescending
        }
    }
    return .orderedSame
}

private func semanticVersionComponents(_ value: String) -> (core: [Int], prerelease: [String]?) {
    let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
    let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    let prerelease = parts.count > 1
        ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        : nil
    return (core, prerelease)
}

/// Parses the GitHub `GET /releases` array. The newest entry is `releases[0]`
/// (pre-releases included — the repo may be pre-release-only, for which
/// `/releases/latest` 404s), whose `tag_name` gives the version and whose
/// `.dmg` asset gives the download url; the release `html_url` is the fallback
/// when no DMG asset is attached. nil for an empty/malformed feed.
func parseGitHubReleases(_ data: Data) -> AppReleaseInfo? {
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let first = array.first,
          let tag = first["tag_name"] as? String else { return nil }
    let version = parseReleaseVersion(tag)
    guard !version.isEmpty else { return nil }
    let htmlURL = (first["html_url"] as? String).flatMap(URL.init(string:))
    let assets = first["assets"] as? [[String: Any]] ?? []
    let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
    let dmgURL = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:))
    guard let downloadURL = dmgURL ?? htmlURL else { return nil }
    return AppReleaseInfo(version: version, downloadURL: downloadURL, htmlURL: htmlURL)
}

/// Parses a bundled `runtime-manifest.json` for the seed's Gateway identity.
/// nil when the file is absent (dev build) or missing either field.
func parseSeedManifest(_ data: Data) -> SeedGatewayVersion? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = object["gatewayVersion"] as? String, !version.isEmpty,
          let buildId = object["gatewayBuildId"] as? String, !buildId.isEmpty else { return nil }
    return SeedGatewayVersion(gatewayVersion: version, gatewayBuildId: buildId)
}

/// Work that must finish before the Gateway runtime may be swapped or rolled
/// back. `MonitorState.restartBlockers()` in sidecar/src/projection/monitor-state.js decides the
/// same thing from the Gateway's own state, and the updater refuses to activate
/// whenever either hands it a non-empty list — so the two must agree exactly.
/// sidecar/test/fixtures/restart-blockers.json is replayed against both.
///
/// Local sessions are excluded: they never run through the Gateway runtime, so
/// restarting it cannot interrupt them.
func restartBlockerLabels(sessions: [GatewaySession], tasks: [MonitorRecord], inbox: [MonitorRecord]) -> [String] {
    let activeSessions = sessions.filter { !$0.isLocalSource && $0.isActive }.count
    let activeTasks = tasks.filter { ["working", "input_required"].contains($0.status ?? "") }.count
    let pendingInbox = inbox.filter { $0.status == "pending" }.count
    return [
        activeSessions > 0 ? "진행 중 세션 \(activeSessions)개" : nil,
        activeTasks > 0 ? "진행 중 태스크 \(activeTasks)개" : nil,
        pendingInbox > 0 ? "미응답 요청 \(pendingInbox)개" : nil
    ].compactMap { $0 }
}
