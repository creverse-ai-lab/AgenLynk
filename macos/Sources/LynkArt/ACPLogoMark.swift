import SwiftUI

/// Native, resolution-independent version of the ACP mark.
/// The structural strokes follow the system primary color so they become
/// black in light mode and white in dark mode; the ACP blue stays constant.
public struct ACPLogoMark: View {
    /// Draws the mark tight to its stroked artwork instead of centring it in
    /// the 210pt design square. At menu bar sizes the design square's margin
    /// wastes roughly half of the available box and the mark reads as tiny.
    public var fitsContentBounds = false

    public init(fitsContentBounds: Bool = false) {
        self.fitsContentBounds = fitsContentBounds
    }

    /// The design square the path coordinates below are authored in.
    private static let designSquare = CGRect(x: 0, y: 0, width: 210, height: 210)
    /// Bounding box of every stroke, including half of the 11pt structural
    /// line width on each side.
    private static let contentBounds = CGRect(x: 44.5, y: 20.5, width: 116, height: 147)

    public var body: some View {
        let box = fitsContentBounds ? Self.contentBounds : Self.designSquare
        Canvas { context, size in
            let scale = min(size.width / box.width, size.height / box.height)
            let offset = CGPoint(
                x: (size.width - box.width * scale) / 2 - box.minX * scale,
                y: (size.height - box.height * scale) / 2 - box.minY * scale
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
        .aspectRatio(box.width / box.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
