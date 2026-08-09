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
        var projected: [Session] = []
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
            projected.append(Session(
                provider: root?.provider ?? key.provider,
                session: frontdoorId,
                state: frontdoorPetState(group, pendingBySession: pendingBySession),
                parent: nil,
                engine: root?.model ?? "\(key.provider)-frontdoor",
                time: petTimestamp(root?.updatedAt ?? latest?.updatedAt, fallback: now),
                inboxPending: 0,
                cwd: (root?.cwd ?? key.cwd).isEmpty ? nil : (root?.cwd ?? key.cwd),
                task: root?.title ?? "Frontdoor",
                delegated: false,
                role: "frontdoor",
                source: root?.source ?? (group.allSatisfy(\.isLocalSource) ? "local" : "gateway")
            ))
            projected.append(contentsOf: workers.map { gatewaySession in
                let pending = pendingBySession[gatewaySession.sessionId] ?? 0
                return Session(
                    provider: gatewaySession.provider,
                    // Gateway session ids are unique across providers. Provider-side
                    // ACP ids are not guaranteed to be, and Pet keys nodes by this value.
                    session: gatewaySession.sessionId,
                    state: petState(for: gatewaySession.status, hasPendingInbox: pending > 0),
                    parent: frontdoorId,
                    engine: gatewaySession.model ?? gatewaySession.provider,
                    time: petTimestamp(gatewaySession.updatedAt, fallback: now),
                    inboxPending: pending,
                    cwd: gatewaySession.cwd.isEmpty ? nil : gatewaySession.cwd,
                    task: gatewaySession.title,
                    delegated: true,
                    role: "worker",
                    source: gatewaySession.source
                )
            })
        }
        return PetSnapshot(sessions: projected)
    }
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

private func frontdoorPetState(
    _ sessions: [GatewaySession],
    pendingBySession: [String: Int]
) -> String {
    let states = sessions.map { session in
        petState(for: session.status, hasPendingInbox: (pendingBySession[session.sessionId] ?? 0) > 0)
    }
    if states.contains(where: { $0 == "running" || $0 == "needs_input" }) { return "running" }
    if states.contains("blocked") { return "blocked" }
    if states.contains("idle") { return "idle" }
    return "offline"
}

private func petState(for status: String, hasPendingInbox: Bool) -> String {
    if hasPendingInbox { return "needs_input" }
    switch status {
    case "running", "cancelling", "restoring": return "running"
    case "waiting_permission", "waiting_input": return "needs_input"
    case "disconnected", "closed": return "offline"
    case "idle": return "idle"
    case "ready": return "ready"
    default: return "blocked"
    }
}

private func petTimestamp(_ value: String?, fallback: Date) -> TimeInterval {
    guard let value else { return fallback.timeIntervalSince1970 }
    return parseTimestamp(value)?.timeIntervalSince1970 ?? fallback.timeIntervalSince1970
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

struct MonitorSnapshot: Sendable {
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

enum MonitorDecodeError: LocalizedError {
    case invalidRoot
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "Monitor snapshot is not a JSON object."
        case .invalidMessage: "Monitor stream delivered an invalid message."
        }
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
