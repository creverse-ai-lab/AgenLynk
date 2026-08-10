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

func eventColor(_ type: String) -> Color {
    if type.contains("error") { return .red }
    if type.contains("permission") || type.contains("elicitation") { return .orange }
    if type.contains("thought") { return .purple }
    if type.contains("tool") { return .cyan }
    if type == "turn_end" { return .green }
    if type == "turn_start" { return .blue }
    return .primary
}

func eventSymbol(_ type: String) -> String {
    if type == "turn_start" { return "arrow.branch" }
    if type == "turn_end" { return "arrow.triangle.merge" }
    if type.contains("thought") { return "brain.head.profile" }
    if type.contains("tool") { return "wrench.and.screwdriver" }
    if type.contains("permission") { return "lock.trianglebadge.exclamation" }
    if type.contains("elicitation") { return "questionmark.bubble" }
    if type.contains("error") { return "exclamationmark.triangle" }
    if type.contains("message") { return "text.bubble" }
    return "circle.fill"
}

func shortTime(_ timestamp: String?) -> String {
    guard let timestamp, let date = parseTimestamp(timestamp) else { return "—" }
    return date.formatted(date: .omitted, time: .standard)
}
