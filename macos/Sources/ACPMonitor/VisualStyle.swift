import ACPShared
import SwiftUI

/// The one status color table (docs/ux-policy.md §3). Every screen colors a
/// session, record, event or request outcome through it: running green,
/// waiting orange, resting and closed grey, failure red. Blue is left for
/// selection and accent.
func statusColor(_ status: String) -> Color {
    switch status {
    case "running", "restoring", "approved": .green
    case "waiting_permission", "waiting_input", "pending", "interrupted": .orange
    case "error", "failed", "denied", "unavailable", "disconnected": .red
    // cancelling is stopping, not waiting on anyone: grey, not orange.
    default: .secondary // idle, ready, end_turn, completed, closed, cancelling, cancelled, answered
    }
}

/// The glyph beside a session status; closed is a stop, never a checkmark.
func sessionStatusSymbol(_ status: String) -> String {
    switch status {
    case "running", "restoring": "bolt.fill"
    case "waiting_permission": "hand.raised.fill"
    case "waiting_input": "keyboard"
    case "cancelling": "xmark.circle"
    case "closed": "stop.circle"
    case "error", "failed": "exclamationmark.triangle.fill"
    default: "pause.circle.fill"
    }
}

func providerColor(_ provider: String) -> Color {
    switch provider.lowercased() {
    // Teal, well away from the accent blue that marks a selection.
    case "codex": Color(red: 0.07, green: 0.62, blue: 0.55)
    case "claude": Color(red: 0.91, green: 0.58, blue: 0.35)
    case "grok": .purple
    case "cursor": .green
    default: .secondary
    }
}

func eventColor(_ kind: String) -> Color {
    switch kind {
    case "error": .red
    case "permission_request", "input_request": .orange
    case "agent_thought": .purple
    case "tool_call", "subagent": .cyan
    case "turn_start", "turn_end", "session_start", "session_end": .secondary
    default: .primary
    }
}

/// Status wins over kind: a failed tool call or turn reads red, and a request
/// still waiting on the user stays orange whatever produced it.
func eventColor(_ event: MonitorEvent) -> Color {
    if let color = requestStateColor(event) { return color }
    if event.isFailed { return statusColor("failed") }
    if event.status == "cancelled" { return statusColor("cancelled") }
    return eventColor(event.kind)
}

func eventSymbol(_ kind: String) -> String {
    switch kind {
    case "turn_start": "arrow.branch"
    case "turn_end": "arrow.triangle.merge"
    case "session_start": "play.circle"
    case "session_end": "stop.circle"
    case "user_message": "person.crop.circle"
    case "agent_message": "text.bubble"
    case "agent_thought": "brain.head.profile"
    case "tool_call": "wrench.and.screwdriver"
    case "permission_request": "lock.trianglebadge.exclamation"
    case "input_request": "questionmark.bubble"
    case "subagent": "person.2"
    case "plan": "list.bullet.clipboard"
    case "compaction": "arrow.down.right.and.arrow.up.left"
    case "error": "exclamationmark.triangle"
    default: "circle.fill"
    }
}

/// A permission / input request reads by its outcome through the status
/// table: waiting orange, approved green, denied red, answered and cancelled
/// grey. nil for other kinds.
func requestStateColor(_ event: MonitorEvent) -> Color? {
    guard let label = event.requestStateLabel else { return nil }
    switch label {
    case "승인됨": return statusColor("approved")
    case "거부됨", "입력 실패": return statusColor("denied")
    case "취소됨": return statusColor("cancelled")
    case "응답됨": return statusColor("completed")
    default: return statusColor("waiting_permission")
    }
}

/// A finished tool call shows how it ended instead of the generic wrench.
func eventSymbol(_ event: MonitorEvent) -> String {
    if event.kind == "permission_request" {
        switch event.requestStateLabel {
        case "승인됨": return "lock.open"
        case "거부됨": return "hand.raised.slash"
        case "취소됨": return "slash.circle"
        default: return eventSymbol(event.kind)
        }
    }
    guard event.kind == "tool_call" || event.kind == "subagent" else { return eventSymbol(event.kind) }
    switch event.status {
    case "completed": return "checkmark.circle"
    case "failed": return "xmark.octagon"
    case "cancelled": return "slash.circle"
    default: return eventSymbol(event.kind)
    }
}

/// Tooltip for every compact context-percent label (menu bar, lanes).
let contextPercentHelp = "최근 요청이 모델 컨텍스트 창을 차지한 비율입니다 (사용 / 창 크기). 세션 누적 토큰과는 다른 값입니다."

/// Context gauge color: calm until the window is nearly full.
func contextColor(_ fraction: Double) -> Color {
    if fraction >= 0.9 { return .red }
    if fraction >= 0.75 { return .orange }
    return .accentColor
}

/// The small bolt that marks a tool call a CLI hook reported as it
/// happened — the link between the hook settings and the timeline.
struct HookMarker: View {
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.green)
            .help("hook으로 실시간 수신")
            .accessibilityLabel("hook으로 실시간 수신")
    }
}

func contextPercentText(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

func shortTime(_ timestamp: String?) -> String {
    guard let timestamp, let date = parseTimestamp(timestamp) else { return "—" }
    return date.formatted(date: .omitted, time: .standard)
}

extension View {
    /// A tooltip only when there is something to say — never an empty
    /// `.help("")`.
    @ViewBuilder func help(ifPresent text: String?) -> some View {
        if let text, !text.isEmpty { self.help(text) } else { self }
    }
}

extension View {
    /// The "대기 중 Worker" box every view folds resting Workers into
    /// (docs/ux-policy.md §13, §14): a subtle, rounded, bordered area set
    /// apart from the moving steps.
    func restingBox(cornerRadius: CGFloat = 8) -> some View {
        self
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
    }
}
