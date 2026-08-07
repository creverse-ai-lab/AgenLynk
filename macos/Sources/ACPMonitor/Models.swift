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

    var id: String { sessionId }
    var displayName: String { title?.isEmpty == false ? title! : sessionId }
    var isActive: Bool {
        ["running", "waiting_permission", "waiting_input", "cancelling", "restoring"].contains(status)
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

        enum CodingKeys: String, CodingKey {
            case provider, session, state, parent, engine, time, cwd, task, delegated, role
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
            let frontdoorId = petFrontdoorId(key)
            let latest = group.max { lhs, rhs in
                petTimestamp(lhs.updatedAt, fallback: now) < petTimestamp(rhs.updatedAt, fallback: now)
            }
            projected.append(Session(
                provider: key.provider,
                session: frontdoorId,
                state: frontdoorPetState(group, pendingBySession: pendingBySession),
                parent: nil,
                engine: "\(key.provider)-frontdoor",
                time: petTimestamp(latest?.updatedAt, fallback: now),
                inboxPending: 0,
                cwd: key.cwd.isEmpty ? nil : key.cwd,
                task: "Frontdoor",
                delegated: false,
                role: "frontdoor"
            ))
            projected.append(contentsOf: group.map { gatewaySession in
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
                    role: "worker"
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
    let identity = key.instanceId ?? "\(key.provider)\u{0}\(key.cwd)"
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
        let tasks = (root.array("tasks") ?? []).enumerated().map { MonitorRecord($0.element, fallbackKind: "task", index: $0.offset) }
        let inbox = (root.array("inbox") ?? []).enumerated().map { MonitorRecord($0.element, fallbackKind: "inbox", index: $0.offset) }
        return MonitorSnapshot(
            connected: root.bool("connected") ?? false,
            streaming: root.bool("streaming") ?? root.bool("connected") ?? false,
            error: root.string("error"),
            gateway: root["gateway"],
            sessions: sessions,
            eventsBySession: eventsBySession,
            tasks: tasks,
            inbox: inbox
        )
    }
}

struct SessionConfigChoice: Identifiable, Equatable, Sendable {
    let value: String
    let name: String
    let description: String?

    var id: String { value }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let rawValue = object.string("value") else { return nil }
        self.value = rawValue
        name = object.string("name") ?? rawValue
        description = object.string("description")
    }
}

struct SessionConfigOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    let type: String
    let currentValue: JSONValue
    let choices: [SessionConfigChoice]

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let id = object.string("id"),
              let type = object.string("type") else { return nil }
        self.id = id
        name = object.string("name") ?? id.replacingOccurrences(of: "_", with: " ").capitalized
        description = object.string("description")
        category = object.string("category")
        self.type = type
        currentValue = object["currentValue"] ?? .null
        choices = (object.array("options") ?? []).compactMap(SessionConfigChoice.init)
    }
}

struct SessionConfigResponse: Sendable {
    let sessionId: String
    let options: [SessionConfigOption]
    let unavailableReason: String?

    static func decode(_ data: Data) throws -> SessionConfigResponse {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let root = JSONValue(any: raw).objectValue,
              let sessionId = root.string("sessionId") else { throw MonitorDecodeError.invalidMessage }
        return SessionConfigResponse(
            sessionId: sessionId,
            options: (root.array("configOptions") ?? []).compactMap(SessionConfigOption.init),
            unavailableReason: root.string("unavailableReason")
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

func parseTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}
