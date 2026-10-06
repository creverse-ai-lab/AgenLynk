import Foundation

/// The built-in pet's looks: logo discs orbiting the cursor like planets, or
/// the AgenLynk mascot doing the same.
enum PetStyle: String, CaseIterable, Sendable {
    case orbit, mochi

    var label: String {
        switch self {
        case .orbit: "천체 (로고)"
        case .mochi: "모찌 (캐릭터)"
        }
    }
}
