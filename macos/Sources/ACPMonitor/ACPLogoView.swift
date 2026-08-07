import AppKit
import SwiftUI

/// Native, resolution-independent version of the ACP mark.
/// The structural strokes follow the system primary color so they become
/// black in light mode and white in dark mode; the ACP blue stays constant.
struct ACPLogoMark: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let scale = side / 210
            let offset = CGPoint(
                x: (size.width - side) / 2,
                y: (size.height - side) / 2
            )

            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
            }

            var outer = Path()
            outer.move(to: point(80, 57))
            outer.addLine(to: point(50, 57))
            outer.addLine(to: point(50, 162))
            outer.addLine(to: point(155, 162))
            outer.addLine(to: point(155, 57))
            outer.addLine(to: point(125, 57))

            var inner = Path()
            inner.move(to: point(75, 130))
            inner.addLine(to: point(75, 94))
            inner.addLine(to: point(131, 94))
            inner.addLine(to: point(131, 130))

            var stem = Path()
            stem.move(to: point(103, 26))
            stem.addLine(to: point(103, 94))

            var signal = Path()
            signal.move(to: point(103, 94))
            signal.addLine(to: point(103, 142))

            let structuralStyle = StrokeStyle(lineWidth: 11 * scale, lineCap: .butt, lineJoin: .miter)
            context.stroke(outer, with: .foreground, style: structuralStyle)
            context.stroke(inner, with: .foreground, style: structuralStyle)
            context.stroke(stem, with: .foreground, style: structuralStyle)
            context.stroke(
                signal,
                with: .color(Color(red: 0.08, green: 0.38, blue: 0.98)),
                style: StrokeStyle(lineWidth: 10 * scale, lineCap: .butt)
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
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
                Text("ACP Monitor").font(.headline)
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
