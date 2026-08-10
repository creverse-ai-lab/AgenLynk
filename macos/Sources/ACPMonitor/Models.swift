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
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func object(_ key: String) -> [String: JSONValue]? { self[key]?.objectValue }
    func array(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }
}

struct GatewaySession: Identifiable, Hashable, Sendable {
    let sessionId: String
    let provider: String
    let model: String?
    let status: String
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

    var id: String { sessionId }
    var displayName: String { title?.isEmpty == false ? title! : sessionId }
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
    }
}

struct FrontdoorSession: Identifiable, Hashable, Sendable {
    let id: String
    let provider: String
    let root: GatewaySession?
    let workers: [GatewaySession]

    var displayName: String { "\(provider.capitalized) Frontdoor" }
    var members: [GatewaySession] { (root.map { [$0] } ?? []) + workers }
    var isActive: Bool { members.contains(where: \.isActive) }
    var activeWorkerCount: Int { workers.filter(\.isActive).count }
    var workspaceCount: Int { Set(members.map(\.cwd).filter { !$0.isEmpty }).count }
    var updatedAt: String? { members.compactMap(\.updatedAt).max() }
    var latestTask: String? {
        members
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            .compactMap(\.title)
            .first { !$0.isEmpty }
    }

    static func make(sessions: [GatewaySession]) -> [FrontdoorSession] {
        let mapped = sessions.filter(\.hasFrontdoorIdentity)
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
            let latest = group.max { lhs, rhs in
                petTimestamp(lhs.updatedAt, fallback: now) < petTimestamp(rhs.updatedAt, fallback: now)
            }
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
                memberStates: memberStates
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
                    memberStates: []
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
/// `src/gateway-service.js` and `src/local-monitor.js`. This is the single
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
    let collapsed = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return nil }
    return String(collapsed.prefix(200))
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

struct MonitorEvent: Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let sequence: Int?
    let type: String
    let timestamp: String?
    let turnId: String?
    let text: String?
    let payload: JSONValue

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let sessionId = object.string("sessionId"),
              let type = object.string("type") else { return nil }
        self.sessionId = sessionId
        sequence = object.int("sequence")
        self.type = type
        timestamp = object.string("ts")
        turnId = object.string("turnId")
        text = object.string("text")
        payload = value
        id = sequence.map { "\(sessionId):\($0)" }
            ?? "\(sessionId):\(timestamp ?? ""):\(type):\(UUID().uuidString)"
    }

    var summary: String {
        if let text, !text.isEmpty {
            return String(text.replacingOccurrences(of: "\n", with: " ").prefix(140))
        }
        guard let object = payload.objectValue else { return type }
        if let data = object.object("data"), let title = data.string("title") { return title }
        if let toolCall = object.object("toolCall"), let title = toolCall.string("title") { return title }
        if let message = object.string("message") { return String(message.prefix(140)) }
        if let reason = object.string("stopReason") { return reason }
        return type.replacingOccurrences(of: "_", with: " ")
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

/// A parsed `monitorApiVersion` string such as `"1.0"`. Minor is additive
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
    static let supportedSchemaVersion = 1
    static let supportedApiMajor = 1

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
    let gatewayIdentity: GatewayIdentity
    let capabilities: JSONValue

    init(_ object: [String: JSONValue]) {
        schemaVersion = object.int("schemaVersion") ?? MonitorCompatibility.supportedSchemaVersion
        monitorApiVersion = object.string("monitorApiVersion") ?? ""
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

struct MonitorSnapshot: Sendable {
    let schemaVersion: Int
    let monitorApiVersion: String
    let connected: Bool
    let streaming: Bool
    let error: String?
    let gateway: JSONValue?
    let sessions: [GatewaySession]
    let eventsBySession: [String: [MonitorEvent]]
    let historySessions: [GatewaySession]
    let historyEventsBySession: [String: [MonitorEvent]]
    let tasks: [MonitorRecord]
    let inbox: [MonitorRecord]

    static func decode(_ data: Data) throws -> MonitorSnapshot {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue else { throw MonitorDecodeError.invalidRoot }
        try MonitorCompatibility.validate(root)
        let sessions = (root.array("sessions") ?? []).compactMap(GatewaySession.init)
        var eventsBySession: [String: [MonitorEvent]] = [:]
        for (sessionId, value) in root.object("events") ?? [:] {
            eventsBySession[sessionId] = (value.arrayValue ?? []).compactMap(MonitorEvent.init)
        }
        let historySessions = (root.array("historySessions") ?? []).compactMap(GatewaySession.init)
        var historyEventsBySession: [String: [MonitorEvent]] = [:]
        for (sessionId, value) in root.object("historyEvents") ?? [:] {
            historyEventsBySession[sessionId] = (value.arrayValue ?? []).compactMap(MonitorEvent.init)
        }
        let tasks = (root.array("tasks") ?? []).enumerated().map { MonitorRecord($0.element, fallbackKind: "task", index: $0.offset) }
        let inbox = (root.array("inbox") ?? []).enumerated().map { MonitorRecord($0.element, fallbackKind: "inbox", index: $0.offset) }
        return MonitorSnapshot(
            schemaVersion: root.int("schemaVersion") ?? MonitorCompatibility.supportedSchemaVersion,
            monitorApiVersion: root.string("monitorApiVersion") ?? "",
            connected: root.bool("connected") ?? false,
            streaming: root.bool("streaming") ?? root.bool("connected") ?? false,
            error: root.string("error"),
            gateway: root["gateway"],
            sessions: sessions,
            eventsBySession: eventsBySession,
            historySessions: historySessions,
            historyEventsBySession: historyEventsBySession,
            tasks: tasks,
            inbox: inbox
        )
    }
}

struct ACPAgentCatalogItem: Identifiable, Equatable, Sendable {
    let registryId: String
    let providerId: String
    let name: String
    let version: String
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

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let registryId = object.string("registryId"),
              let providerId = object.string("providerId") else { return nil }
        self.registryId = registryId
        self.providerId = providerId
        name = object.string("name") ?? registryId
        version = object.string("version") ?? "—"
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
    let versions: [RuntimeVersionSummary]

    var current: RuntimeVersionSummary? { versions.first(where: \.isCurrent) }
    var previous: RuntimeVersionSummary? { versions.first(where: \.isPrevious) }
    var canRollback: Bool { previous != nil }

    init?(_ value: JSONValue) {
        guard let root = value.objectValue else { return nil }
        let current = root.object("current")
        runtimeRoot = root.string("runtimeRoot") ?? ""
        currentVersionId = current?.string("runtimeRoot").map { ($0 as NSString).lastPathComponent }
        currentGatewayVersion = current?.string("gatewayVersion")
        currentGatewayBuildId = current?.string("gatewayBuildId")
        previousVersionId = root.object("previous")?.string("runtimeRoot").map { ($0 as NSString).lastPathComponent }
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

struct GatewayConfigOption: Identifiable, Equatable, Sendable {
    let id: String
    let group: String
    let type: String
    let label: String
    let description: String
    let unit: String?
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
        description = object.string("description") ?? ""
        unit = object.string("unit")
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

/// A warning when the running Gateway daemon serves from a different runtime
/// root than the monitor — the split-brain state the Node monitor annotates
/// onto its setup info. Left unsurfaced, the user keeps running old Gateway
/// code with no visible sign; a safe restart respawns from the monitor's
/// runtime and heals it.
func runtimeSplitWarning(gateway: JSONValue?) -> String? {
    guard let split = gateway?.objectValue?.object("runtimeSplit"),
          let daemonRoot = split.string("daemonRuntimeRoot") else { return nil }
    return "실행 중인 Gateway가 다른 runtime(\(daemonRoot))에서 동작하고 있습니다. Gateway 구성에서 '적용 및 안전 재시작'을 실행하면 현재 runtime으로 전환됩니다."
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
        "Monitor 인증이 유효하지 않습니다. '다시 연결'을 눌러 세션을 새로 만드세요."
    case "monitor_restart_blocked":
        "진행 중인 세션·Task·미응답 요청이 끝나면 다시 시도하세요."
    default:
        nil
    }
}

func decodeJSONValue(_ data: Data) throws -> JSONValue {
    JSONValue(any: try JSONSerialization.jsonObject(with: data))
}

private let fractionalISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let standardISO8601Formatter = ISO8601DateFormatter()

func parseTimestamp(_ value: String) -> Date? {
    fractionalISO8601Formatter.date(from: value) ?? standardISO8601Formatter.date(from: value)
}

func monitorTimestamp(_ date: Date) -> String {
    fractionalISO8601Formatter.string(from: date)
}
