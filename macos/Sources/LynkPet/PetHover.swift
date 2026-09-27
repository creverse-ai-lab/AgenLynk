import CoreGraphics
import Foundation

// Pure hover helpers for the Pet overlay: which node the cursor points at,
// what its bubble says, and where the bubble goes. No AppKit/SwiftUI here, so
// the same file compiles into the macOS check runner (scripts/test-models.sh).

/// A drawn node as the hit-test sees it, in window (top-left origin) points.
struct PetHoverCandidate: Equatable {
    let id: String
    let center: CGPoint
    let radius: CGFloat
}

/// The node under `point`: the nearest candidate whose disc, grown by `slop`,
/// contains it. Nearest wins so two touching nodes never both claim the cursor.
func petHoveredNodeID(_ candidates: [PetHoverCandidate], at point: CGPoint, slop: CGFloat = 6) -> String? {
    var best: (id: String, distance: CGFloat)?
    for candidate in candidates {
        let distance = hypot(point.x - candidate.center.x, point.y - candidate.center.y)
        guard distance <= candidate.radius + slop else { continue }
        if best == nil || distance < best!.distance { best = (candidate.id, distance) }
    }
    return best?.id
}

/// docs/ux-policy.md §3 status phrases. `contractState` is the pet-state
/// value when the agent came from the contract; otherwise the renderer's own
/// legacy state string (running / needs_input / blocked / ready / idle /
/// offline) is phrased.
func petStatusPhrase(contractState: String?, legacyState: String, waitingReason: String?) -> String {
    let waiting = waitingReason == "permission" ? "권한 대기" : "입력 대기"
    if let contractState {
        switch contractState {
        case "running", "starting": return "실행 중"
        case "waiting": return waiting
        case "failed": return "오류"
        case "idle", "completed": return "대기"
        case "offline": return "종료"
        default: return "알 수 없음"
        }
    }
    switch legacyState {
    case "running": return "실행 중"
    case "needs_input": return waiting
    case "blocked": return "오류"
    case "ready", "idle": return "대기"
    case "offline": return "종료"
    default: return "알 수 없음"
    }
}

/// Role wording (docs/ux-policy.md §1): Frontdoor / Worker, nested Workers
/// as "Worker · N단" — never "Agent"/"Subagent".
func petRoleLabel(role: String?, depth: Int) -> String {
    if role == "frontdoor" { return "Frontdoor" }
    return depth >= 2 ? "Worker · \(depth)단" : "Worker"
}

/// Provider display name (docs/ux-policy.md §2), never the raw id.
func petProviderLabel(_ provider: String) -> String {
    switch provider.lowercased() {
    case "claude": return "Claude"
    case "codex", "chatgpt": return "Codex"
    case "grok": return "Grok"
    case "", "unknown": return "알 수 없는 CLI"
    default: return provider.capitalized
    }
}

/// One line of at most `limit` characters, "…" when cut.
func petOneLine(_ text: String, limit: Int) -> String {
    let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.count > limit else { return line }
    return String(line.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
}

/// What a hovered node's bubble says: name, then "role · status · provider",
/// then the task when it adds something the name does not.
struct PetHoverText: Equatable {
    let title: String
    let detail: String
    let task: String?
}

let petHoverTitleLimit = 32
let petHoverTaskLimit = 44

func petHoverText(
    name: String?,
    fallbackName: String,
    role: String?,
    depth: Int,
    status: String,
    provider: String,
    task: String?
) -> PetHoverText {
    let trimmedName = petOneLine(name ?? "", limit: Int.max)
    let fullName = trimmedName.isEmpty ? petOneLine(fallbackName, limit: Int.max) : trimmedName
    let detail = [petRoleLabel(role: role, depth: depth), status, petProviderLabel(provider)].joined(separator: " · ")
    let fullTask = petOneLine(task ?? "", limit: Int.max)
    // A task that only repeats the name (older producers name nodes by task)
    // is not shown twice.
    let taskLine = fullTask.isEmpty || fullTask == fullName ? nil : petOneLine(fullTask, limit: petHoverTaskLimit)
    return PetHoverText(title: petOneLine(fullName, limit: petHoverTitleLimit), detail: detail, task: taskLine)
}

/// Where the bubble of `size` goes for a node at `center` with `nodeRadius`:
/// above the node, below when the top would clip, then clamped inside
/// `bounds` with `inset`. Window (top-left origin) coordinates.
func petBubbleRect(size: CGSize, center: CGPoint, nodeRadius: CGFloat, bounds: CGRect, gap: CGFloat = 8, inset: CGFloat = 4) -> CGRect {
    var y = center.y - nodeRadius - gap - size.height
    if y < bounds.minY + inset { y = center.y + nodeRadius + gap }
    y = min(max(y, bounds.minY + inset), bounds.maxY - inset - size.height)
    var x = center.x - size.width / 2
    x = min(max(x, bounds.minX + inset), bounds.maxX - inset - size.width)
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

/// Whether the cursor has left a held graph: beyond the outermost node's
/// reach (plus `margin`) from the hub. Screen distances.
func petHoldReleased(mouse: CGPoint, hub: CGPoint, reach: CGFloat, margin: CGFloat = 18) -> Bool {
    hypot(mouse.x - hub.x, mouse.y - hub.y) > reach + margin
}
