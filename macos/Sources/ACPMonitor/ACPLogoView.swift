import AppKit
import LynkArt
import SwiftUI

/// The same mark as `ACPLogoMark`, rasterized once as a template image so the
/// menu bar tints it for the current appearance instead of drawing the ACP blue
/// stroke on a bar that may be light, dark or over a wallpaper.
@MainActor
enum ACPMenuBarIcon {
    /// Full status-item height. The mark is drawn tight to its artwork, so this
    /// is the height of the strokes themselves rather than a design square.
    static let height: CGFloat = 18
    /// Matches the tight artwork's 116:147 aspect ratio.
    static let width: CGFloat = (height * 116 / 147).rounded()

    static let image: NSImage = {
        let size = NSSize(width: width, height: height)
        let renderer = ImageRenderer(
            content: ACPLogoMark(fitsContentBounds: true)
                .foregroundStyle(Color.black)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image: NSImage
        if let cgImage = renderer.cgImage {
            image = NSImage(cgImage: cgImage, size: size)
        } else {
            image = NSImage(size: size)
        }
        image.isTemplate = true
        return image
    }()
}

struct ACPLogoLockup: View {
    let subtitle: String?

    init(subtitle: String? = nil) {
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: 9) {
            ACPLogoMark().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("AgenLynk").font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ACPAppIconArtwork: View {
    let dark: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 102, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: dark
                            ? [Color(red: 0.13, green: 0.14, blue: 0.16), Color(red: 0.06, green: 0.06, blue: 0.07)]
                            : [.white, Color(red: 0.93, green: 0.94, blue: 0.96)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(32)
            ACPLogoMark()
                .foregroundStyle(dark ? Color.white : Color(red: 0.06, green: 0.06, blue: 0.08))
                .padding(51)
        }
        .frame(width: 512, height: 512)
        .background(Color.clear)
    }
}

@MainActor
private enum ACPAppIconRenderer {
    static func make(dark: Bool) -> NSImage {
        let view = NSHostingView(rootView: ACPAppIconArtwork(dark: dark))
        view.frame = NSRect(x: 0, y: 0, width: 512, height: 512)
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return NSImage(size: NSSize(width: 512, height: 512))
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

private final class ACPAppearanceTrackingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateApplicationIcon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateApplicationIcon()
    }

    private func updateApplicationIcon() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSApp.applicationIconImage = ACPAppIconRenderer.make(dark: dark)
    }
}

struct ACPApplicationIconUpdater: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ACPAppearanceTrackingView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
