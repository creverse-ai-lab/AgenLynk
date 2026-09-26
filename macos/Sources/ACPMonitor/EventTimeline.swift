import Foundation

/// A run of consecutive tool calls in one turn of one session. Timelines are
/// dominated by tool calls, so a run collapses into one representative row
/// that expands to the calls' compact headers on click.
struct ToolCallGroup: Identifiable, Equatable, Sendable {
    /// Oldest first; always at least two calls.
    let events: [MonitorEvent]

    /// Stable while the run grows: new calls append, the first stays.
    var id: String { "tools:\(events[0].id)" }
    var sessionId: String { events[0].sessionId }
    var timestamp: String? { events[0].timestamp }

    /// The call still running — one a hook reported live first, since that
    /// is the one really running now — else the latest.
    var representative: MonitorEvent {
        events.last(where: { $0.isInFlight && $0.isHookObserved })
            ?? events.last(where: \.isInFlight)
            ?? events[events.count - 1]
    }
    var failedCount: Int { events.filter(\.isFailed).count }
    var isRunning: Bool { events.contains(where: \.isInFlight) }
    /// Some call in the run arrived through a CLI hook.
    var isHookObserved: Bool { events.contains(where: \.isHookObserved) }

    /// "도구 12개 · 실행 중: Bash: npm test… · 실패 2", or "… · 마지막: …"
    /// when nothing runs.
    func summary(titleLimit: Int = 28) -> String {
        let lead = isRunning ? "실행 중" : "마지막"
        var text = "도구 \(events.count)개 · \(lead): \(representative.compactToolTitle(limit: titleLimit))"
        if failedCount > 0 { text += " · 실패 \(failedCount)" }
        return text
    }
}

/// One entry of a grouped timeline: a single event, or a run of tool calls.
enum TimelineItem: Identifiable, Equatable, Sendable {
    case event(MonitorEvent)
    case tools(ToolCallGroup)

    var id: String {
        switch self {
        case let .event(event): event.id
        case let .tools(group): group.id
        }
    }

    var sessionId: String {
        switch self {
        case let .event(event): event.sessionId
        case let .tools(group): group.sessionId
        }
    }
}

/// One rendered row: an event, a collapsed/expanded tool group header, or a
/// tool call shown under its expanded group.
struct TimelineRow: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case event(MonitorEvent)
        case group(ToolCallGroup, expanded: Bool)
    }

    let content: Content
    /// The expanded group this event row belongs to, nil for a top-level row.
    let parentGroupId: String?

    var id: String {
        switch content {
        case let .event(event): event.id
        case let .group(group, _): group.id
        }
    }

    var sessionId: String {
        switch content {
        case let .event(event): event.sessionId
        case let .group(group, _): group.sessionId
        }
    }

    var timestamp: String? {
        switch content {
        case let .event(event): event.timestamp
        case let .group(group, _): group.timestamp
        }
    }

    /// The events this row stands for on screen — what a call/응답 arrow
    /// anchored on one of them is drawn on. An expanded header stands for
    /// none: its calls have their own rows.
    var coveredEventIds: [String] {
        switch content {
        case let .event(event): [event.id]
        case let .group(group, expanded): expanded ? [] : group.events.map(\.id)
        }
    }
}

enum EventTimeline {
    /// Collapses runs of consecutive `tool_call` events of the same session
    /// and turn into one `ToolCallGroup`. Anything else between two calls —
    /// a message, a thought, a permission or input request, a turn boundary,
    /// or another session's event — ends the run, so permission requests
    /// always stay visible on their own. Runs shorter than `minimumRun`
    /// stay as single events. Order is preserved.
    static func group(_ events: [MonitorEvent], minimumRun: Int = 2) -> [TimelineItem] {
        var items: [TimelineItem] = []
        items.reserveCapacity(events.count)
        var run: [MonitorEvent] = []

        func flush() {
            if run.count >= max(minimumRun, 2) {
                items.append(.tools(ToolCallGroup(events: run)))
            } else {
                items.append(contentsOf: run.map(TimelineItem.event))
            }
            run.removeAll(keepingCapacity: true)
        }

        for event in events {
            if event.kind == "tool_call" {
                // Calls with no known turn (a hook that arrived before the
                // transcript) are not assumed to share one.
                if let last = run.last, last.sessionId != event.sessionId || last.turnId != event.turnId || event.turnId == nil {
                    flush()
                }
                run.append(event)
            } else {
                flush()
                items.append(.event(event))
            }
        }
        flush()
        return items
    }

    /// Flattens grouped items into rows, inserting an expanded group's calls
    /// right under its header.
    static func rows(_ items: [TimelineItem], expanded: Set<String>) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(items.count)
        for item in items {
            switch item {
            case let .event(event):
                rows.append(TimelineRow(content: .event(event), parentGroupId: nil))
            case let .tools(group):
                let isExpanded = expanded.contains(group.id)
                rows.append(TimelineRow(content: .group(group, expanded: isExpanded), parentGroupId: nil))
                if isExpanded {
                    rows.append(contentsOf: group.events.map { TimelineRow(content: .event($0), parentGroupId: group.id) })
                }
            }
        }
        return rows
    }

    /// The event to keep in place while older events load above: the first
    /// row that stands for an event on screen. An expanded group header
    /// covers none, so its first call (the next row) anchors instead; a
    /// collapsed group anchors on its newest call, which stays in the group
    /// when older calls join it.
    static func anchorEventId(in rows: [TimelineRow]) -> String? {
        rows.lazy.compactMap { $0.coveredEventIds.last }.first
    }

    /// The row that shows `eventId` after a refresh: its own row, or the
    /// collapsed group that now covers it.
    static func rowId(showing eventId: String, in rows: [TimelineRow]) -> String? {
        rows.first { $0.coveredEventIds.contains(eventId) }?.id
    }

    /// The trailing tool run of a session's timeline, when its newest item is
    /// one — what "지금 무엇을 하는가" should summarize instead of one call.
    static func trailingToolGroup(_ events: [MonitorEvent]) -> ToolCallGroup? {
        guard case let .tools(group)? = lastItem(events) else { return nil }
        return group
    }

    /// `group(events).last`, found by walking back over the trailing run of
    /// tool calls only — a session's newest item without grouping its whole
    /// timeline. The run rule is `group`'s: a call joins the one before it
    /// when both are tool calls of the same session and the same known turn.
    static func lastItem(_ events: [MonitorEvent]) -> TimelineItem? {
        guard let last = events.last else { return nil }
        guard last.kind == "tool_call" else { return .event(last) }
        var start = events.count - 1
        while start > 0 {
            let previous = events[start - 1]
            let current = events[start]
            guard previous.kind == "tool_call",
                  current.turnId != nil,
                  previous.sessionId == current.sessionId,
                  previous.turnId == current.turnId else { break }
            start -= 1
        }
        let run = Array(events[start...])
        return run.count >= 2 ? .tools(ToolCallGroup(events: run)) : .event(last)
    }

    /// The `before` cursor for loading a session's older events: its lowest
    /// loaded sequence. nil when nothing older can exist (sequence 1 is the
    /// first event the monitor ever assigned) or no event carries one.
    static func olderCursor(in events: [MonitorEvent]) -> Int? {
        guard let oldest = events.compactMap(\.sequence).min(), oldest > 1 else { return nil }
        return oldest
    }
}

/// Which dashboard side panels the window has room for. The sequence in the
/// middle always keeps its minimum; the inspector folds first because the
/// session list is how a scope is chosen, then the session list.
struct DashboardPanelLayout: Equatable, Sendable {
    static let centerMinimum: CGFloat = 420
    static let sessionsMinimum: CGFloat = 190
    static let inspectorMinimum: CGFloat = 240

    let fitsSessions: Bool
    let fitsInspector: Bool
    /// Room for both side panels beside the sequence.
    let fitsBoth: Bool
    private(set) var showsSessions: Bool
    let showsInspector: Bool

    /// `force*` opens a panel the width folded away (the user asked for it).
    init(width: CGFloat, wantsSessions: Bool, wantsInspector: Bool, forceSessions: Bool = false, forceInspector: Bool = false) {
        fitsSessions = width >= Self.centerMinimum + Self.sessionsMinimum
        let roomForBoth = width >= Self.centerMinimum + Self.sessionsMinimum + Self.inspectorMinimum
        fitsBoth = roomForBoth
        showsSessions = (wantsSessions && fitsSessions) || forceSessions
        // With the session list hidden the inspector only needs its own room.
        fitsInspector = showsSessions ? roomForBoth : width >= Self.centerMinimum + Self.inspectorMinimum
        // A panel forced open where both do not fit takes the other's place
        // rather than squeezing the sequence below its minimum.
        let forcedSessionsCrowd = forceSessions && !roomForBoth
        showsInspector = ((wantsInspector && fitsInspector) && !forcedSessionsCrowd) || forceInspector
        if forceInspector && !roomForBoth && !forceSessions { showsSessions = false }
    }
}
