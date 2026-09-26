import ACPShared
import SwiftUI

func statusColor(_ status: String) -> Color {
    switch status {
    case "running", "restoring": .blue
    case "idle", "end_turn", "completed": .green
    case "waiting_permission", "waiting_input", "cancelling", "interrupted": .orange
    case "error", "failed", "unavailable": .red
    default: .secondary
    }
}

func providerColor(_ provider: String) -> Color {
    switch provider.lowercased() {
    case "codex": Color(red: 0.30, green: 0.64, blue: 1.00)
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
    case "turn_end", "session_end": .green
    case "turn_start", "session_start", "user_message": .blue
    default: .primary
    }
}

/// Status wins over kind: a failed tool call or turn reads red, and a request
/// still waiting on the user stays orange whatever produced it.
func eventColor(_ event: MonitorEvent) -> Color {
    if let color = requestStateColor(event) { return color }
    if event.isFailed { return .red }
    if event.status == "cancelled" { return .secondary }
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

/// A permission / input request reads by its outcome: waiting orange,
/// approved green, denied red, cancelled grey. nil for other kinds.
func requestStateColor(_ event: MonitorEvent) -> Color? {
    guard let label = event.requestStateLabel else { return nil }
    switch label {
    case "승인됨", "응답됨": return .green
    case "거부됨", "입력 실패": return .red
    case "취소됨": return .secondary
    default: return .orange
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

/// Human word for an event status, nil when the event carries none.
func eventStatusLabel(_ status: String?) -> String? {
    switch status {
    case "pending": "대기"
    case "running": "실행 중"
    case "completed": "완료"
    case "failed": "실패"
    case "cancelled": "취소"
    default: nil
    }
}

/// Tooltip for every compact context-percent label (menu bar, lanes).
let contextPercentHelp = "최근 요청이 모델 컨텍스트 창을 차지한 비율입니다 (사용 / 창 크기). 세션 누적 토큰과는 다른 값입니다."

/// Context gauge color: calm until the window is nearly full.
func contextColor(_ fraction: Double) -> Color {
    if fraction >= 0.9 { return .red }
    if fraction >= 0.75 { return .orange }
    return .blue
}

func contextPercentText(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

func shortTime(_ timestamp: String?) -> String {
    guard let timestamp, let date = parseTimestamp(timestamp) else { return "—" }
    return date.formatted(date: .omitted, time: .standard)
}
