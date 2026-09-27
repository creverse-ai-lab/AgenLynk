import AppKit
import SwiftUI

/// The agent's mark (Claude, Codex, Grok) wherever a session or Frontdoor is
/// named, so the provider reads at a glance and the text can carry the task.
/// The images are the ones the Pet already ships; the build copies them to
/// Contents/Resources/ProviderIcons. Without them (a bare `swift run`), a
/// provider-colored disc with an initial stands in.
struct ProviderIcon: View {
    let provider: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = Self.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Circle().fill(providerColor(provider))
                    Text(String(Self.label(provider).prefix(1)))
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .help(Self.label(provider))
        .accessibilityLabel(Self.label(provider))
    }

    static func label(_ provider: String) -> String { providerDisplayLabel(provider) }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(for provider: String) -> NSImage? {
        let key = provider.lowercased()
        if let cached = cache[key] { return cached }
        guard ["claude", "codex", "grok"].contains(key),
              let url = Bundle.main.url(forResource: key, withExtension: "jpg", subdirectory: "ProviderIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }
}
