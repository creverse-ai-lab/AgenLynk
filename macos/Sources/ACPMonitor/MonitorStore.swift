import Combine
import Foundation

struct MonitorReducerState: Equatable, Sendable {
    var gateway: JSONValue?
    var sessions: [GatewaySession] = []
    var eventsBySession: [String: [MonitorEvent]] = [:]
    var historySessions: [GatewaySession] = []
    var historyEventsBySession: [String: [MonitorEvent]] = [:]
    /// Older events paged in on demand (GET /api/sessions/:id/events). Kept
    /// apart from the live/history buckets so the stream's per-session cap
    /// never trims them away; merged into the log by id.
    var pagedEventsBySession: [String: [MonitorEvent]] = [:]
    var logSessions: [GatewaySession] = []
    var logEventsBySession: [String: [MonitorEvent]] = [:]
    var tasks: [MonitorRecord] = []
    var inbox: [MonitorRecord] = []
    var connected = false
    var streaming = false
    var eventLimit = MonitorReducerDefaults.eventLimit
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

/// Deterministic Monitor state transitions shared by snapshots, SSE `state`
/// envelopes, and SSE `events` frames. It owns no tasks or transport.
///
/// Monitor API v2 frames carry only what changed: `events` (in an `events`
/// frame or a `state` frame) are upserted by id, never a replacement of the
/// session's bucket. Only a full snapshot replaces buckets wholesale. A session
/// that leaves the live list moves to history with its events, exactly as the
/// sidecar's `MonitorState.removeSession` does, so the log never loses them.
enum MonitorReducer {
    static func apply(snapshot: MonitorSnapshot, to state: inout MonitorReducerState) -> MonitorReducerEffect {
        var effect = MonitorReducerEffect()
        if state.gateway != snapshot.gateway {
            state.gateway = snapshot.gateway
            effect.gatewayChanged = true
        }
        state.eventLimit = snapshot.eventLimit
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
        var fullRebuild = false
        // POST /api/history clear: everything not live is gone on disk and in
        // the sidecar, so it goes here too.
        if message.bool("historyCleared") == true, clearHistory(in: &state) {
            fullRebuild = true
        }
        let removedSessionIds = (message.array("removedSessionIds") ?? []).compactMap { $0.stringValue }
        for sessionId in removedSessionIds where archiveSession(sessionId, status: nil, in: &state) {
            fullRebuild = true
        }
        if let values = message.array("sessions") {
            let next = values.compactMap(GatewaySession.init)
            // The sidecar's setSessions archives whatever leaves the list,
            // named in removedSessionIds or not; so does this.
            let nextIds = Set(next.map(\.sessionId))
            for session in state.sessions where !nextIds.contains(session.sessionId) {
                _ = archiveSession(session.sessionId, status: nil, in: &state)
            }
            if state.sessions != next {
                state.sessions = next
                fullRebuild = true
            }
            // A session that came back is live again, not history.
            for session in next where reviveSession(session.sessionId, in: &state) {
                fullRebuild = true
            }
        }
        var touched: Set<String> = []
        if let buckets = message.object("events") {
            touched = upsert(decodeEventBuckets(buckets), into: &state)
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
        if fullRebuild {
            rebuildLog(in: &state)
        } else if !touched.isEmpty {
            rebuildLog(sessionIds: touched, in: &state)
        }
        effect.logChanged = fullRebuild || !touched.isEmpty
        return effect
    }

    /// An SSE `events` frame: `{events: {sessionId: [changed events]}}`.
    @discardableResult
    static func applyEventsMessage(_ message: [String: JSONValue], to state: inout MonitorReducerState) -> Bool {
        guard let buckets = message.object("events") else { return false }
        return upsert(events: decodeEventBuckets(buckets), to: &state)
    }

    /// Upserts changed events by id into their sessions' buckets (history for
    /// a session that is only in history, live otherwise — the sidecar keeps
    /// events for sessions its list has not named yet under live too).
    @discardableResult
    static func upsert(events changes: [String: [MonitorEvent]], to state: inout MonitorReducerState) -> Bool {
        let touched = upsert(changes, into: &state)
        guard !touched.isEmpty else { return false }
        rebuildLog(sessionIds: touched, in: &state)
        return true
    }

    /// Older events of one session, oldest first, as the events endpoint pages
    /// them. Upserted by id; returns whether anything new arrived.
    @discardableResult
    static func prependOlder(_ events: [MonitorEvent], sessionId: String, to state: inout MonitorReducerState) -> Bool {
        let incoming = events.filter { $0.sessionId == sessionId }
        guard !incoming.isEmpty else { return false }
        let known = Set((state.logEventsBySession[sessionId] ?? []).map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return false }
        state.pagedEventsBySession[sessionId] = upsertMonitorEvents(
            fresh, into: state.pagedEventsBySession[sessionId] ?? [], limit: Int.max
        )
        rebuildLog(sessionIds: [sessionId], in: &state)
        return true
    }

    /// Drops every history session and event (and paged-in events) of a
    /// session that is not live. Returns whether anything was removed.
    static func clearHistory(in state: inout MonitorReducerState) -> Bool {
        let liveIds = Set(state.sessions.map(\.sessionId))
        let hadHistory = !state.historySessions.isEmpty || !state.historyEventsBySession.isEmpty
            || state.pagedEventsBySession.keys.contains { !liveIds.contains($0) }
        guard hadHistory else { return false }
        state.historySessions.removeAll { !liveIds.contains($0.sessionId) }
        state.historyEventsBySession = state.historyEventsBySession.filter { liveIds.contains($0.key) }
        state.pagedEventsBySession = state.pagedEventsBySession.filter { liveIds.contains($0.key) }
        return true
    }

    /// `session_removed`: the Gateway closed the session. It moves to history
    /// as `closed` with its events, matching `removeSession(id, {closed})`.
    static func removeSession(_ sessionId: String, from state: inout MonitorReducerState) {
        if archiveSession(sessionId, status: "closed", in: &state) { rebuildLog(in: &state) }
    }

    private static func decodeEventBuckets(_ buckets: [String: JSONValue]) -> [String: [MonitorEvent]] {
        var result: [String: [MonitorEvent]] = [:]
        for (sessionId, value) in buckets {
            let events = (value.arrayValue ?? []).compactMap(MonitorEvent.init).filter { $0.sessionId == sessionId }
            if !events.isEmpty { result[sessionId] = events }
        }
        return result
    }

    /// Returns the session ids whose buckets actually changed.
    private static func upsert(_ changes: [String: [MonitorEvent]], into state: inout MonitorReducerState) -> Set<String> {
        var touched: Set<String> = []
        let liveIds = Set(state.sessions.map(\.sessionId))
        let historyIds = Set(state.historySessions.map(\.sessionId))
        for (sessionId, events) in changes where !events.isEmpty {
            let toHistory = historyIds.contains(sessionId) && !liveIds.contains(sessionId)
            let current = (toHistory ? state.historyEventsBySession[sessionId] : state.eventsBySession[sessionId]) ?? []
            let next = upsertMonitorEvents(events, into: current, limit: state.eventLimit)
            guard next != current else { continue }
            if toHistory {
                state.historyEventsBySession[sessionId] = next
            } else {
                state.eventsBySession[sessionId] = next
            }
            touched.insert(sessionId)
        }
        if !touched.isEmpty { state.lastAgentEventAt = heartbeat(existing: state.lastAgentEventAt) }
        return touched
    }

    /// Moves a known live session (and its live events) into history. Unknown
    /// ids are ignored: without a session record there is nothing to show.
    private static func archiveSession(_ sessionId: String, status: String?, in state: inout MonitorReducerState) -> Bool {
        guard let session = state.sessions.first(where: { $0.sessionId == sessionId }) else { return false }
        state.sessions.removeAll { $0.sessionId == sessionId }
        state.historySessions.removeAll { $0.sessionId == sessionId }
        state.historySessions.append(status.map { session.with(status: $0) } ?? session)
        if let live = state.eventsBySession.removeValue(forKey: sessionId) {
            let history = state.historyEventsBySession[sessionId] ?? []
            state.historyEventsBySession[sessionId] = upsertMonitorEvents(live, into: history, limit: state.eventLimit)
        }
        return true
    }

    /// The reverse of `archiveSession` for a session reported live again.
    private static func reviveSession(_ sessionId: String, in state: inout MonitorReducerState) -> Bool {
        guard state.historySessions.contains(where: { $0.sessionId == sessionId }) else { return false }
        state.historySessions.removeAll { $0.sessionId == sessionId }
        if let history = state.historyEventsBySession.removeValue(forKey: sessionId) {
            let live = state.eventsBySession[sessionId] ?? []
            state.eventsBySession[sessionId] = upsertMonitorEvents(live, into: history, limit: state.eventLimit)
        }
        return true
    }

    static func rebuildLog(in state: inout MonitorReducerState) {
        var sessionsById: [String: GatewaySession] = [:]
        for session in state.historySessions { sessionsById[session.sessionId] = session }
        for session in state.sessions { sessionsById[session.sessionId] = session }
        state.logSessions = Array(sessionsById.values).sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }

        var merged: [String: [MonitorEvent]] = [:]
        let keys = Set(state.eventsBySession.keys)
            .union(state.historyEventsBySession.keys)
            .union(state.pagedEventsBySession.keys)
        for sessionId in keys {
            merged[sessionId] = mergedLog(sessionId, in: state)
        }
        state.logEventsBySession = merged
    }

    /// Recomputes only the given sessions' log buckets — an `events` frame
    /// touches a few sessions, and rebuilding every bucket 10×/s during a busy
    /// turn was the cost the old append path existed to avoid.
    private static func rebuildLog(sessionIds: Set<String>, in state: inout MonitorReducerState) {
        for sessionId in sessionIds {
            let merged = mergedLog(sessionId, in: state)
            state.logEventsBySession[sessionId] = merged.isEmpty ? nil : merged
        }
    }

    /// History and live buckets are disjoint by session in v2; merging by id
    /// keeps a transiently duplicated event (mid-archive) from showing twice.
    private static func mergedLog(_ sessionId: String, in state: MonitorReducerState) -> [MonitorEvent] {
        let history = state.historyEventsBySession[sessionId] ?? []
        let live = state.eventsBySession[sessionId] ?? []
        let paged = state.pagedEventsBySession[sessionId] ?? []
        var merged: [MonitorEvent]
        if history.isEmpty { merged = live }
        else if live.isEmpty { merged = history }
        else { merged = upsertMonitorEvents(live, into: history, limit: Int.max) }
        if paged.isEmpty { return merged }
        if merged.isEmpty { return paged }
        // Live/history copies are newer than a paged-in one with the same id.
        return upsertMonitorEvents(merged, into: paged, limit: Int.max)
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

    func resetForNewSidecar() {
        state.appliedSnapshotRevision = nil
    }

    func stop() {
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

    /// An SSE `events` frame. The sidecar already coalesces changes per
    /// broadcast window, so frames are applied as they arrive.
    func applyEventsMessage(_ message: [String: JSONValue]) {
        var next = state
        if MonitorReducer.applyEventsMessage(message, to: &next) {
            state = next
            logRevision += 1
        }
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

    /// Older events paged in for one session.
    func prependOlder(_ events: [MonitorEvent], sessionId: String) {
        var next = state
        if MonitorReducer.prependOlder(events, sessionId: sessionId, to: &next) {
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
