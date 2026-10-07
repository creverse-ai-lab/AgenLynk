import Foundation

/// The built-in pet's looks: logo discs orbiting the cursor like planets, or
/// the AgenLynk mascot as a little devil or a little mermaid doing the same.
/// With a mascot, sub-agents become its companions (bats and fireballs, or
/// fish and bubbles).
enum PetStyle: String, CaseIterable, Sendable {
    case orbit, devil, mermaid

    var label: String {
        switch self {
        case .orbit: "천체 (로고)"
        case .devil: "소악마 (캐릭터)"
        case .mermaid: "인어 (캐릭터)"
        }
    }

    /// A stored value, including "mochi", which named the devil before the
    /// mermaid joined it.
    init?(stored: String) {
        if stored == "mochi" { self = .devil } else if let style = PetStyle(rawValue: stored) { self = style } else { return nil }
    }
}
