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
    // The stream/agent heartbeat clocks live in `MonitorHeartbeat`, not here:
    // a frame that only moves the clock must not republish (and diff) this.
}

struct MonitorReducerEffect: Equatable, Sendable {
    var disconnectedError: String?
    var pausedSubscriptionNotice: String?
    /// Sessions or events changed: the merged log was rebuilt.
    var logChanged = false
    /// Some agent event was inserted or changed (drives "마지막 에이전트 이벤트").
    var eventsChanged = false
    /// Anything in the state changed at all; the store publishes only then.
    var stateChanged = false
}

/// Deterministic Monitor state transitions shared by snapshots, SSE `state`
/// envelopes, and SSE `events` frames. It owns no tasks or transport.
///
/// Monitor API v2 frames carry only what changed: `events` (in an `events`
/// frame or a `state` frame) are upserted by id, never a replacement of the
/// session's bucket. A snapshot sets which sessions exist and merges its
/// (newest-N) events into their buckets by id. A session
/// that leaves the live list moves to history with its events, exactly as the
/// sidecar's `MonitorState.removeSession` does, so the log never loses them.
enum MonitorReducer {
    static func apply(snapshot: MonitorSnapshot, to state: inout MonitorReducerState) -> MonitorReducerEffect {
        var effect = MonitorReducerEffect()
        if state.gateway != snapshot.gateway {
            state.gateway = snapshot.gateway
            effect.stateChanged = true
        }
        if state.eventLimit != snapshot.eventLimit {
            state.eventLimit = snapshot.eventLimit
            effect.stateChanged = true
        }
        let dataUnchanged = snapshot.revision != nil && snapshot.revision == state.appliedSnapshotRevision
        if !dataUnchanged {
            // The snapshot carries only each session's newest events
            // (`snapshotEventLimit`); the stream may have grown a bucket past
            // that. Merge by id so a poll never shrinks what is on screen or
            // opens a gap below paged-in history the cursor would not refetch.
            let liveEvents = mergeSnapshotBuckets(
                snapshot.eventsBySession, existing: state.eventsBySession,
                fallback: state.historyEventsBySession, limit: state.eventLimit)
            let historyEvents = mergeSnapshotBuckets(
                snapshot.historyEventsBySession, existing: state.historyEventsBySession,
                fallback: state.eventsBySession, limit: state.eventLimit)
            let eventsChanged = state.eventsBySession != liveEvents
                || state.historyEventsBySession != historyEvents
            effect.logChanged = eventsChanged
                || state.sessions != snapshot.sessions
                || state.historySessions != snapshot.historySessions
            if state.tasks != snapshot.tasks || state.inbox != snapshot.inbox
                || state.appliedSnapshotRevision != snapshot.revision {
                effect.stateChanged = true
            }
            state.sessions = snapshot.sessions
            state.eventsBySession = liveEvents
            state.historySessions = snapshot.historySessions
            state.historyEventsBySession = historyEvents
            state.tasks = snapshot.tasks
            state.inbox = snapshot.inbox
            state.appliedSnapshotRevision = snapshot.revision
            // Paged-in older events of a session the monitor no longer knows
            // (neither live nor history) would otherwise stay forever.
            if prunePagedEvents(in: &state) { effect.logChanged = true }
            if effect.logChanged {
                rebuildLog(in: &state)
                effect.stateChanged = true
            }
        }
        if state.connected != snapshot.connected || state.streaming != snapshot.streaming {
            state.connected = snapshot.connected
            state.streaming = snapshot.streaming
            effect.stateChanged = true
        }
        if !snapshot.connected { effect.disconnectedError = snapshot.error ?? "Gateway에 연결되지 않았습니다." }
        return effect
    }

    /// Buckets for exactly the sessions the snapshot lists, each the snapshot's
    /// events upserted into what was already held (live or history, as a
    /// session may have just moved between them).
    static func mergeSnapshotBuckets(
        _ incoming: [String: [MonitorEvent]],
        existing: [String: [MonitorEvent]],
        fallback: [String: [MonitorEvent]],
        limit: Int
    ) -> [String: [MonitorEvent]] {
        var merged: [String: [MonitorEvent]] = [:]
        merged.reserveCapacity(incoming.count)
        for (sessionId, events) in incoming {
            guard var bucket = existing[sessionId] ?? fallback[sessionId], !bucket.isEmpty else {
                merged[sessionId] = events
                continue
            }
            upsertMonitorEvents(events, into: &bucket, limit: limit)
            merged[sessionId] = bucket
        }
        return merged
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
                if archiveSession(session.sessionId, status: nil, in: &state) { fullRebuild = true }
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
            let tasks = values.enumerated().map { MonitorRecord($0.element, fallbackKind: "task", index: $0.offset) }
            if state.tasks != tasks {
                state.tasks = tasks
                effect.stateChanged = true
            }
        }
        if let values = message.array("inbox") {
            let inbox = values.enumerated().map { MonitorRecord($0.element, fallbackKind: "inbox", index: $0.offset) }
            if state.inbox != inbox {
                state.inbox = inbox
                effect.stateChanged = true
            }
        }
        if let connected = message.bool("connected"), state.connected != connected {
            state.connected = connected
            effect.stateChanged = true
        }
        if let streaming = message.bool("streaming"), state.streaming != streaming {
            state.streaming = streaming
            effect.stateChanged = true
        }
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
        effect.eventsChanged = !touched.isEmpty
        if effect.logChanged { effect.stateChanged = true }
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
        var paged = state.pagedEventsBySession[sessionId] ?? []
        // Bounded: past the cap the oldest paged events fall off.
        guard upsertMonitorEvents(fresh, into: &paged, limit: MonitorReducerDefaults.pagedEventLimit) else { return false }
        state.pagedEventsBySession[sessionId] = paged
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
    @discardableResult
    static func removeSession(_ sessionId: String, from state: inout MonitorReducerState) -> Bool {
        if !archiveSession(sessionId, status: "closed", in: &state) {
            // The session list dropped it first: the close still lands on its
            // history row, or it would keep the last status the list showed.
            guard let index = state.historySessions.firstIndex(where: { $0.sessionId == sessionId }),
                  state.historySessions[index].status != "closed" else { return false }
            state.historySessions[index] = state.historySessions[index].with(status: "closed")
        }
        rebuildLog(in: &state)
        return true
    }

    /// Drops paged buckets of sessions that are neither live nor history
    /// (by session record or event bucket). Returns whether any went.
    static func prunePagedEvents(in state: inout MonitorReducerState) -> Bool {
        guard !state.pagedEventsBySession.isEmpty else { return false }
        var known = Set(state.sessions.map(\.sessionId))
        known.formUnion(state.historySessions.map(\.sessionId))
        known.formUnion(state.eventsBySession.keys)
        known.formUnion(state.historyEventsBySession.keys)
        let kept = state.pagedEventsBySession.filter { known.contains($0.key) }
        guard kept.count != state.pagedEventsBySession.count else { return false }
        state.pagedEventsBySession = kept
        return true
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
            var bucket = (toHistory ? state.historyEventsBySession[sessionId] : state.eventsBySession[sessionId]) ?? []
            guard upsertMonitorEvents(events, into: &bucket, limit: state.eventLimit) else { continue }
            if toHistory {
                state.historyEventsBySession[sessionId] = bucket
            } else {
                state.eventsBySession[sessionId] = bucket
            }
            touched.insert(sessionId)
        }
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
        guard let firstMerged = merged.first else { return paged }
        // Paged events are older than anything live: join the two at the
        // sequence boundary instead of re-upserting every paged event on each
        // frame. `ts` is first-observed and stable, so a paged event sharing
        // an id with a live one can never sort before the live bucket's head.
        var low = 0
        var high = paged.count
        while low < high {
            let mid = (low + high) / 2
            if withinSessionEventOrder(paged[mid], firstMerged) { low = mid + 1 } else { high = mid }
        }
        if low == paged.count { return paged + merged }
        // Paged events overlapping the live range (rare): merge by id, the
        // live/history copy winning, as before.
        return upsertMonitorEvents(merged, into: paged, limit: Int.max)
    }
}

/// When the Monitor stream last delivered anything, and when an agent event
/// last changed. Kept out of `MonitorReducerState` and out of `AppModel`'s
/// change forwarding: only the views that print these clocks observe it, so a
/// frame that moves nothing but the clock re-renders nothing else.
@MainActor
final class MonitorHeartbeat: ObservableObject {
    @Published private(set) var lastStreamMessageAt: Date?
    @Published private(set) var lastAgentEventAt: Date?

    func markStreamMessage(now: Date = Date()) {
        let next = Self.coalesced(lastStreamMessageAt, now: now)
        if next != lastStreamMessageAt { lastStreamMessageAt = next }
    }

    func markAgentEvent(now: Date = Date()) {
        let next = Self.coalesced(lastAgentEventAt, now: now)
        if next != lastAgentEventAt { lastAgentEventAt = next }
    }

    /// At most one tick per second: the display is relative to the second.
    nonisolated static func coalesced(_ existing: Date?, now: Date) -> Date {
        guard let existing, now.timeIntervalSince(existing) < 1 else { return now }
        return existing
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var state = MonitorReducerState()
    @Published private(set) var logRevision = 0
    /// Advances on every published state change (a superset of
    /// `logRevision`); derived values are cached against it.
    private(set) var revision = 0
    let heartbeat = MonitorHeartbeat()

    /// The newest sidecar revision a stream frame carried. A snapshot older
    /// than it predates state already applied, and must not replace it.
    private(set) var streamRevision = 0

    func resetForNewSidecar() {
        // Not observable: only the next snapshot's comparison reads it.
        state.appliedSnapshotRevision = nil
        // A fresh sidecar counts from zero.
        streamRevision = 0
    }

    func noteStreamRevision(_ revision: Int) {
        if revision > streamRevision { streamRevision = revision }
    }

    /// Whether `snapshot` is at least as new as everything the stream applied.
    func isCurrent(_ snapshot: MonitorSnapshot) -> Bool {
        guard let revision = snapshot.revision else { return true }
        return revision >= streamRevision
    }

    func stop() {
        setConnection(connected: false, streaming: false)
    }

    @discardableResult
    func apply(_ snapshot: MonitorSnapshot) -> MonitorReducerEffect {
        var next = state
        let effect = MonitorReducer.apply(snapshot: snapshot, to: &next)
        commit(next, effect)
        return effect
    }

    @discardableResult
    func applyStateMessage(_ message: [String: JSONValue]) -> MonitorReducerEffect {
        var next = state
        let effect = MonitorReducer.applyStateMessage(message, to: &next)
        commit(next, effect)
        return effect
    }

    /// An SSE `events` frame. The sidecar already coalesces changes per
    /// broadcast window, so frames are applied as they arrive.
    func applyEventsMessage(_ message: [String: JSONValue]) {
        var next = state
        guard MonitorReducer.applyEventsMessage(message, to: &next) else { return }
        commit(next, MonitorReducerEffect(logChanged: true, eventsChanged: true, stateChanged: true))
    }

    func markStreamMessage() {
        heartbeat.markStreamMessage()
    }

    func setGateway(_ gateway: JSONValue?) {
        guard state.gateway != gateway else { return }
        var next = state
        next.gateway = gateway
        commit(next, MonitorReducerEffect(stateChanged: true))
    }

    func setConnection(connected: Bool, streaming: Bool) {
        guard state.connected != connected || state.streaming != streaming else { return }
        var next = state
        next.connected = connected
        next.streaming = streaming
        commit(next, MonitorReducerEffect(stateChanged: true))
    }

    /// Older events paged in for one session.
    func prependOlder(_ events: [MonitorEvent], sessionId: String) {
        var next = state
        guard MonitorReducer.prependOlder(events, sessionId: sessionId, to: &next) else { return }
        commit(next, MonitorReducerEffect(logChanged: true, stateChanged: true))
    }

    func removeSession(_ sessionId: String) {
        var next = state
        guard MonitorReducer.removeSession(sessionId, from: &next) else { return }
        commit(next, MonitorReducerEffect(logChanged: true, stateChanged: true))
    }

    /// Publishes only what the reducer reported as changed — never a
    /// whole-state comparison.
    private func commit(_ next: MonitorReducerState, _ effect: MonitorReducerEffect) {
        guard effect.stateChanged else { return }
        revision &+= 1
        state = next
        if effect.logChanged { logRevision += 1 }
        if effect.eventsChanged { heartbeat.markAgentEvent() }
    }
}
