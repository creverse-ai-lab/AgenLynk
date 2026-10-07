import AppKit
import LynkArt
import SwiftUI

extension AgentMascot.Mood {
    /// The mood for a session's state, as the notch reads it.
    init(urgency: MenuBarPipeline.Urgency) {
        switch urgency {
        case .permission, .input: self = .waiting
        case .running: self = .working
        case .error: self = .failed
        case .idle: self = .happy
        case .closed: self = .idle
        }
    }
}

extension PetStyle {
    /// The mascot the notch and cards show: the chosen one, or the mermaid
    /// while the pet itself is the logo orbit.
    var mascotKind: AgentMascot.Kind { self == .devil ? .devil : .mermaid }
}

#if DEBUG
/// Debug-only sheet of every agent and mood, rendered to a PNG for review.
struct AgentMascotSheet: View {
    var body: some View {
        let providers = ["claude", "codex", "grok", "agenlynk"]
        let moods: [AgentMascot.Mood] = [.idle, .working, .waiting, .happy, .failed]
        VStack(alignment: .leading, spacing: 18) {
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 18) {
                    ForEach(Array(moods.enumerated()), id: \.offset) { _, mood in
                        AgentMascot(provider: provider, size: 140, mood: mood)
                    }
                    AgentMascot(provider: provider, size: 44, mood: .working)
                    AgentMascot(provider: provider, size: 28, mood: .idle)
                    AgentMascot(provider: provider, size: 18, mood: .idle)
                }
            }
        }
        .padding(24)
        .background(Color(white: 0.08))
    }

    @MainActor
    static func write(to path: String) {
        let renderer = ImageRenderer(content: AgentMascotSheet())
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
