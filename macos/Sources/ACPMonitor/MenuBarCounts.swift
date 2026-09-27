import Foundation

/// What the status item says, from the menu bar pipeline (pure, tested).
struct MenuBarCounts: Equatable {
    /// Frontdoors with anything moving (running, waiting on the user, failed).
    let main: Int
    /// Their Workers that are running or waiting on the user.
    let sub: Int
    let permission: Int
    let input: Int

    init(_ pipeline: MenuBarPipeline) {
        let cards = pipeline.activeCards
        main = cards.count
        sub = cards.reduce(0) { total, card in
            total + card.stages.filter { $0.depth > 0 && $0.urgency <= .running && $0.urgency != .error }.count
        }
        permission = pipeline.permissionCount
        input = pipeline.inputCount
    }

    /// "2 | 5", then "· 권한 1" / "· 입력 1" while the user is needed; nil when idle.
    var text: String? {
        guard main > 0 || sub > 0 else { return nil }
        var value = "\(main) | \(sub)"
        if permission > 0 { value += " · 권한 \(permission)" } else if input > 0 { value += " · 입력 \(input)" }
        return value
    }

    var accessibility: String {
        var parts = ["AgenLynk"]
        if main > 0 || sub > 0 { parts.append("작업 중 Frontdoor \(main)개, Worker \(sub)개") }
        if permission > 0 { parts.append("권한 대기 \(permission)") }
        if input > 0 { parts.append("입력 대기 \(input)") }
        return parts.joined(separator: ", ")
    }
}
