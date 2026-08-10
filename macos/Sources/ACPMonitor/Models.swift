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

    static func validate(_ object: [String: JSONValue]) throws {
        guard let schemaVersion = object.int("schemaVersion"), schemaVersion == supportedSchemaVersion else {
            throw MonitorDecodeError.updateRequired("Monitor schema version이 호환되지 않습니다. 앱을 업데이트하세요.")
        }
        guard let rawApiVersion = object.string("monitorApiVersion"),
              let apiVersion = MonitorApiVersion(rawApiVersion),
              apiVersion.major == supportedApiMajor else {
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

enum MonitorDecodeError: LocalizedError {
    case invalidRoot
    case invalidMessage
    case updateRequired(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "Monitor snapshot is not a JSON object."
        case .invalidMessage: "Monitor stream delivered an invalid message."
        case let .updateRequired(message): message
        }
    }
}

/// A Node Monitor HTTP error response, `{error, code}`. `code` is a stable
/// identifier callers can branch on (auth failure, incompatible API,
/// restart blocked, ...); `error` stays the human-readable message.
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
