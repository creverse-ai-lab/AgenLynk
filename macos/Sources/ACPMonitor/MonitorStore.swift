import Combine
import Foundation

struct MonitorReducerState: Equatable, Sendable {
    var gateway: JSONValue?
    var sessions: [GatewaySession] = []
    var eventsBySession: [String: [MonitorEvent]] = [:]
    var historySessions: [GatewaySession] = []
    var historyEventsBySession: [String: [MonitorEvent]] = [:]
    var logSessions: [GatewaySession] = []
    var logEventsBySession: [String: [MonitorEvent]] = [:]
    var tasks: [MonitorRecord] = []
    var inbox: [MonitorRecord] = []
    var connected = false
    var streaming = false
    var appliedSnapshotRevision: Int?
    var lastStreamMessageAt: Date?
    var lastAgentEventAt: Date?
}

struct MonitorReducerEffect: Equatable, Sendable {
    var disconnectedError: String?
    var pausedSubscriptionNotice: String?
    var gatewayChanged = false
    var logChanged = false
}

/// Deterministic Monitor state transitions shared by snapshots, SSE state
/// envelopes, and batched event delivery. It owns no tasks or transport.
enum MonitorReducer {
    static func apply(snapshot: MonitorSnapshot, to state: inout MonitorReducerState) -> MonitorReducerEffect {
        var effect = MonitorReducerEffect()
        if state.gateway != snapshot.gateway {
            state.gateway = snapshot.gateway
            effect.gatewayChanged = true
        }
        let dataUnchanged = snapshot.revision != nil && snapshot.revision == state.appliedSnapshotRevision
        if !dataUnchanged {
            effect.logChanged = state.sessions != snapshot.sessions
                || state.eventsBySession != snapshot.eventsBySession
                || state.historySessions != snapshot.historySessions
                || state.historyEventsBySession != snapshot.historyEventsBySession
            state.sessions = snapshot.sessions
            state.eventsBySession = snapshot.eventsBySession
            state.historySessions = snapshot.historySessions
            state.historyEventsBySession = snapshot.historyEventsBySession
            state.tasks = snapshot.tasks
            state.inbox = snapshot.inbox
            state.appliedSnapshotRevision = snapshot.revision
            if effect.logChanged { rebuildLog(in: &state) }
        }
        state.connected = snapshot.connected
        state.streaming = snapshot.streaming
        if !snapshot.connected { effect.disconnectedError = snapshot.error ?? "Gateway에 연결되지 않았습니다." }
        return effect
    }

    static func applyStateMessage(_ message: [String: JSONValue], to state: inout MonitorReducerState) -> MonitorReducerEffect {
        var effect = MonitorReducerEffect()
        let removedSessionIds = (message.array("removedSessionIds") ?? []).compactMap(\.stringValue)
        if !removedSessionIds.isEmpty {
            let priorSessions = Dictionary(state.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, last in last })
            for sessionId in removedSessionIds {
                guard let session = priorSessions[sessionId] else { continue }
                archiveRemovedSession(session, liveEvents: state.eventsBySession[sessionId] ?? [], into: &state)
                effect.logChanged = true
            }
        }
        if let values = message.array("sessions") {
            let next = values.compactMap(GatewaySession.init)
            if state.sessions != next {
                state.sessions = next
                effect.logChanged = true
            }
            let validIds = Set(state.sessions.map(\.sessionId))
            let nextEvents = state.eventsBySession.filter { validIds.contains($0.key) }
            if state.eventsBySession != nextEvents {
                state.eventsBySession = nextEvents
                effect.logChanged = true
            }
        }
        for sessionId in removedSessionIds {
            if state.eventsBySession.removeValue(forKey: sessionId) != nil { effect.logChanged = true }
        }
        if let buckets = message.object("events") {
            for (sessionId, value) in buckets {
                let next = (value.arrayValue ?? []).compactMap(MonitorEvent.init)
                if next.isEmpty {
                    if state.eventsBySession.removeValue(forKey: sessionId) != nil { effect.logChanged = true }
                } else if state.eventsBySession[sessionId] != next {
                    state.eventsBySession[sessionId] = next
                    effect.logChanged = true
                    state.lastAgentEventAt = heartbeat(existing: state.lastAgentEventAt)
                }
            }
        }
        if let values = message.array("tasks") {
            state.tasks = values.enumerated().map { MonitorRecord($0.element, fallbackKind: "task", index: $0.offset) }
        }
        if let values = message.array("inbox") {
            state.inbox = values.enumerated().map { MonitorRecord($0.element, fallbackKind: "inbox", index: $0.offset) }
        }
        if let connected = message.bool("connected") { state.connected = connected }
        if let streaming = message.bool("streaming") { state.streaming = streaming }
        if !state.connected { effect.disconnectedError = message.string("error") ?? "Gateway 연결 끊김" }
        effect.pausedSubscriptionNotice = MonitorStreamNotice.forPausedSubscription(
            connected: state.connected,
            streaming: message.bool("streaming"),
            error: message.string("error")
        )
        if effect.logChanged { rebuildLog(in: &state) }
        return effect
    }

    @discardableResult
    static func append(events additions: [MonitorEvent], to state: inout MonitorReducerState) -> Bool {
        var changed = false
        for (sessionId, batch) in Dictionary(grouping: additions, by: \.sessionId) {
            var current = state.eventsBySession[sessionId] ?? []
            let currentTail = current.last
            var sequences = Set(current.compactMap(\.sequence))
            var accepted: [MonitorEvent] = []
            for event in batch {
                if let sequence = event.sequence, !sequences.insert(sequence).inserted { continue }
                current.append(event)
                accepted.append(event)
            }
            guard !accepted.isEmpty else { continue }
            let acceptedInOrder = zip(accepted, accepted.dropFirst()).allSatisfy { !withinSessionEventOrder($1, $0) }
                && (currentTail == nil || accepted.first == nil || !withinSessionEventOrder(accepted.first!, currentTail!))
            if current.count > 1 && !acceptedInOrder {
                current.sort(by: withinSessionEventOrder)
            }
            if current.count > 2_000 { current.removeFirst(current.count - 2_000) }
            state.eventsBySession[sessionId] = current

            var logged = state.logEventsBySession[sessionId] ?? []
            let known = Set(logged.map(\.id))
            let tail = logged.last
            let fresh = accepted.filter { !known.contains($0.id) }
            logged.append(contentsOf: fresh)
            if logged.count > 2_000 { logged.removeFirst(logged.count - 2_000) }
            let appendedInOrder = zip(fresh, fresh.dropFirst()).allSatisfy { !withinSessionEventOrder($1, $0) }
                && (tail == nil || fresh.first == nil || !withinSessionEventOrder(fresh.first!, tail!))
            if logged.count > 1 && !appendedInOrder { logged.sort(by: withinSessionEventOrder) }
            state.logEventsBySession[sessionId] = logged
            changed = true
        }
        if changed { state.lastAgentEventAt = heartbeat(existing: state.lastAgentEventAt) }
        return changed
    }

    static func removeSession(_ sessionId: String, from state: inout MonitorReducerState) {
        state.sessions.removeAll { $0.sessionId == sessionId }
        state.eventsBySession.removeValue(forKey: sessionId)
        rebuildLog(in: &state)
    }

    private static func archiveRemovedSession(
        _ session: GatewaySession,
        liveEvents: [MonitorEvent],
        into state: inout MonitorReducerState
    ) {
        state.historySessions.removeAll { $0.sessionId == session.sessionId }
        state.historySessions.append(session)
        var byId: [String: MonitorEvent] = [:]
        for event in state.historyEventsBySession[session.sessionId] ?? [] { byId[event.id] = event }
        for event in liveEvents { byId[event.id] = event }
        var merged = Array(byId.values).sorted(by: withinSessionEventOrder)
        if merged.count > 2_000 { merged.removeFirst(merged.count - 2_000) }
        state.historyEventsBySession[session.sessionId] = merged
    }

    static func rebuildLog(in state: inout MonitorReducerState) {
        var sessionsById: [String: GatewaySession] = [:]
        for session in state.historySessions { sessionsById[session.sessionId] = session }
        for session in state.sessions { sessionsById[session.sessionId] = session }
        state.logSessions = Array(sessionsById.values).sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }

        var merged: [String: [MonitorEvent]] = [:]
        for sessionId in Set(state.eventsBySession.keys).union(state.historyEventsBySession.keys) {
            var byId: [String: MonitorEvent] = [:]
            for event in state.historyEventsBySession[sessionId] ?? [] { byId[event.id] = event }
            for event in state.eventsBySession[sessionId] ?? [] { byId[event.id] = event }
            merged[sessionId] = Array(byId.values).sorted(by: withinSessionEventOrder)
        }
        state.logEventsBySession = merged
    }

    private static func heartbeat(existing: Date?, now: Date = Date()) -> Date {
        guard let existing, now.timeIntervalSince(existing) < 1 else { return now }
        return existing
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var state = MonitorReducerState()
    @Published private(set) var logRevision = 0
    private var pendingEvents: [MonitorEvent] = []
    private var flushTask: Task<Void, Never>?

    func resetForNewSidecar() {
        flushTask?.cancel()
        flushTask = nil
        pendingEvents.removeAll(keepingCapacity: true)
        state.appliedSnapshotRevision = nil
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
        pendingEvents.removeAll(keepingCapacity: true)
        state.connected = false
        state.streaming = false
    }

    @discardableResult
    func apply(_ snapshot: MonitorSnapshot) -> MonitorReducerEffect {
        var next = state
        let effect = MonitorReducer.apply(snapshot: snapshot, to: &next)
        if next != state { state = next }
        if effect.logChanged { logRevision += 1 }
        return effect
    }

    @discardableResult
    func applyStateMessage(_ message: [String: JSONValue]) -> MonitorReducerEffect {
        var next = state
        next.lastStreamMessageAt = Self.heartbeat(existing: next.lastStreamMessageAt)
        let effect = MonitorReducer.applyStateMessage(message, to: &next)
        if next != state { state = next }
        if effect.logChanged { logRevision += 1 }
        return effect
    }

    func markStreamMessage() {
        var next = state
        next.lastStreamMessageAt = Self.heartbeat(existing: next.lastStreamMessageAt)
        if next != state { state = next }
    }

    func setGateway(_ gateway: JSONValue?) {
        guard state.gateway != gateway else { return }
        var next = state
        next.gateway = gateway
        state = next
    }

    func setConnection(connected: Bool, streaming: Bool) {
        guard state.connected != connected || state.streaming != streaming else { return }
        var next = state
        next.connected = connected
        next.streaming = streaming
        state = next
    }

    func enqueue(_ event: MonitorEvent) {
        pendingEvents.append(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flush()
        }
    }

    func flush() {
        flushTask = nil
        guard !pendingEvents.isEmpty else { return }
        let pending = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        var next = state
        if MonitorReducer.append(events: pending, to: &next) {
            state = next
            logRevision += 1
        }
    }

    func removeSession(_ sessionId: String) {
        var next = state
        MonitorReducer.removeSession(sessionId, from: &next)
        if next != state {
            state = next
            logRevision += 1
        }
    }

    private static func heartbeat(existing: Date?, now: Date = Date()) -> Date {
        guard let existing, now.timeIntervalSince(existing) < 1 else { return now }
        return existing
    }
}
