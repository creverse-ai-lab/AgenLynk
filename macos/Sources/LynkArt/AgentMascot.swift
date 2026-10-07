import AppKit
import SwiftUI

/// The real provider marks (Claude, Codex, Grok) for the mascot's forehead.
/// LynkArt ships no artwork of its own: the Monitor and the Pet each bundle
/// the marks and register them at launch. Without one the mascot draws a
/// stand-in emblem. Lock-guarded rather than main-actor, so it can be read
/// from any view helper on every SDK.
public final class AgentMarks: @unchecked Sendable {
    public static let shared = AgentMarks()
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    public func register(_ provider: String, image: NSImage) {
        lock.lock()
        defer { lock.unlock() }
        images[provider.lowercased()] = image
    }

    public func image(for provider: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[provider.lowercased()]
    }
}

/// AgenLynk's mascot: a cute little devil with Mochi's soft squircle body
/// (after Coucou), horns and a spade tail, holding a spear whose head is the
/// AgenLynk mark. Each agent has its own: body colors, horns and tail in the
/// agent's color, and its mark on the forehead. Drawn in code so it scales
/// from the notch pill to a card and changes expression with the session.
public struct AgentMascot: View {
    public enum Mood: Equatable, Sendable {
        case idle, working, waiting, happy, failed
    }

    public let provider: String
    public var size: CGFloat
    public var mood: Mood = .idle
    /// The AgenLynk spear in its hand; dropped at small sizes either way.
    public var holdsStaff = true

    public init(provider: String, size: CGFloat, mood: Mood = .idle, holdsStaff: Bool = true) {
        self.provider = provider
        self.size = size
        self.mood = mood
        self.holdsStaff = holdsStaff
    }

    public var body: some View {
        let style = MascotStyle(provider: provider)
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animates)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.3))
                    .frame(width: bodyWidth * 0.8, height: size * 0.07)
                    .blur(radius: size * 0.025)
                    .offset(y: size * 0.4)
                if size >= 26 {
                    tail(style, phase: phase)
                        .offset(y: bob(phase))
                }
                if holdsStaff && size >= 30 { spear(style) }
                character(style, phase: phase)
                    .offset(y: bob(phase))
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("\(Self.label(provider)) 봇")
    }

    static func label(_ provider: String) -> String {
        switch provider.lowercased() {
        case "claude": "Claude"
        case "codex": "Codex"
        case "grok": "Grok"
        default: "AgenLynk"
        }
    }

    private var bodyWidth: CGFloat { size * 0.72 }
    private var bodyHeight: CGFloat { size * 0.56 }
    private var animates: Bool { mood == .working || mood == .waiting }

    /// A gentle bob while working; little hops while it waits on the person.
    private func bob(_ phase: Double) -> CGFloat {
        switch mood {
        case .working: CGFloat(sin(phase * 3.2)) * size * 0.022
        case .waiting: CGFloat(abs(sin(phase * 5))) * -size * 0.035
        default: 0
        }
    }

    // MARK: Character

    private func character(_ style: MascotStyle, phase: Double) -> some View {
        let width = bodyWidth
        let height = bodyHeight
        return ZStack {
            if size >= 20 {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    ZStack {
                        LinearGradient(colors: [style.hornTip, style.horn], startPoint: .top, endPoint: .bottom)
                        // Lit from the top left on both horns: the mask is
                        // flipped, the light is not.
                        LinearGradient(colors: [Color.white.opacity(0.5), .clear, Color.black.opacity(0.22)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .mask(Horn().scaleEffect(x: side, y: 1))
                    .frame(width: width * 0.2, height: height * 0.36)
                    .shadow(color: .black.opacity(0.28), radius: width * 0.015, x: width * 0.006, y: height * 0.02)
                    .offset(x: side * width * 0.27, y: -height * 0.56)
                }
            }
            // The soft squircle body (Mochi's superellipse): solid, lit from
            // the top, its face brightest in the middle and rounding off to a
            // slightly darker edge, like a soft cushion. No outline or glassy
            // rim, which read as see-through.
            Squircle()
                .fill(LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom))
            Squircle()
                .fill(RadialGradient(stops: [
                    .init(color: Color.white.opacity(0.35), location: 0),
                    .init(color: .clear, location: 0.55),
                    .init(color: style.ink.opacity(0.16), location: 1)
                ], center: UnitPoint(x: 0.45, y: 0.38), startRadius: 0, endRadius: width * 0.62))
            face(style, width: width, height: height, phase: phase)
            if size >= 22 {
                // The agent's mark on the forehead, between the horns: the
                // real one when the host registered it.
                Group {
                    if let mark = AgentMarks.shared.image(for: provider) {
                        Image(nsImage: mark)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            // The artwork is a rounded square; trim its rim.
                            .scaleEffect(1.12)
                    } else {
                        AgentEmblem(provider: provider, color: style.emblem)
                            .padding(width * 0.03)
                            .background(Circle().fill(style.pin))
                    }
                }
                    .frame(width: width * 0.22, height: width * 0.22)
                    .clipShape(Circle())
                    // A glassy cap: light across the top, shade at the bottom.
                    // Set into the forehead: shade inside its lower rim.
                    .overlay(Circle()
                        .stroke(Color.black.opacity(0.35), lineWidth: width * 0.03)
                        .blur(radius: width * 0.01)
                        .offset(y: width * 0.008)
                        .mask(Circle()))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.75), lineWidth: max(0.5, width * 0.012)))
                    .shadow(color: .black.opacity(0.25), radius: width * 0.02, y: width * 0.012)
                    .offset(y: -height * 0.3)
            }
            if size >= 30, let badge = statusBadge { badge.offset(x: -width * 0.48, y: height * 0.32) }
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.28), radius: size * 0.03, y: size * 0.02)
        .offset(y: size * 0.07)
    }

    @ViewBuilder
    private func face(_ style: MascotStyle, width: CGFloat, height: CGFloat, phase: Double) -> some View {
        let eyeWidth = width * 0.085
        let eyeHeight = height * 0.2
        let spacing = width * 0.15
        let blink = mood == .working || mood == .idle
            ? (phase.truncatingRemainder(dividingBy: 4.2) < 0.12 ? 0.15 : 1.0)
            : 1.0
        let eyeY = height * (mood == .waiting ? 0.0 : 0.05)
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Group {
                    switch mood {
                    case .happy:
                        HappyEye()
                            .stroke(style.ink, style: StrokeStyle(lineWidth: eyeWidth * 0.7, lineCap: .round))
                            .frame(width: eyeWidth * 2, height: eyeHeight * 0.4)
                    case .failed:
                        Image(systemName: "xmark")
                            .font(.system(size: eyeHeight * 0.7, weight: .heavy))
                            .foregroundStyle(style.ink)
                    case .waiting:
                        Capsule().fill(style.ink).frame(width: eyeWidth * 1.15, height: eyeHeight * 1.12)
                            .overlay(catchlight(eyeWidth: eyeWidth * 1.15, eyeHeight: eyeHeight * 1.12))
                    default:
                        Capsule().fill(style.ink).frame(width: eyeWidth, height: eyeHeight)
                            .overlay(catchlight(eyeWidth: eyeWidth, eyeHeight: eyeHeight).opacity(blink < 1 ? 0 : 1))
                            .scaleEffect(x: 1, y: blink)
                    }
                }
                .offset(x: side * spacing, y: eyeY)
                // Cheeks.
                Ellipse()
                    .fill(Color(red: 1, green: 0.47, blue: 0.59).opacity(mood == .failed ? 0.15 : 0.45))
                    .frame(width: width * 0.13, height: height * 0.08)
                    .blur(radius: width * 0.012)
                    .offset(x: side * spacing * 1.75, y: eyeY + height * 0.15)
            }
            mouth(style, width: width, height: height)
        }
    }

    /// The glint in an open eye; too small to read below a mid size.
    @ViewBuilder
    private func catchlight(eyeWidth: CGFloat, eyeHeight: CGFloat) -> some View {
        if size >= 30 {
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: eyeWidth * 0.5, height: eyeWidth * 0.5)
                .offset(x: -eyeWidth * 0.12, y: -eyeHeight * 0.24)
        }
    }

    /// A small open smile with one fang peeking from its top, the devil's
    /// tell; none when it failed. The fang sits on the dark of the mouth so it
    /// reads as a tooth, not as a stray mark on the light face.
    @ViewBuilder
    private func mouth(_ style: MascotStyle, width: CGFloat, height: CGFloat) -> some View {
        if size >= 26 && mood != .failed {
            let mouthWidth = width * 0.17
            let mouthHeight = height * 0.12
            ZStack(alignment: .top) {
                OpenSmile()
                    .fill(style.ink)
                    .frame(width: mouthWidth, height: mouthHeight)
                Fang()
                    .fill(Color.white)
                    .frame(width: mouthWidth * 0.26, height: mouthHeight * 0.5)
                    .offset(x: mouthWidth * 0.2)
            }
            .offset(y: height * 0.23)
        }
    }

    /// Mochi's speech-bubble badge: what the devil is up to.
    private var statusBadge: AnyView? {
        let (symbol, color): (String, Color)
        switch mood {
        case .working: (symbol, color) = ("ellipsis", Color(red: 0.23, green: 0.62, blue: 1))
        case .waiting: (symbol, color) = ("exclamationmark", .orange)
        case .happy: (symbol, color) = ("checkmark", .green)
        case .failed: (symbol, color) = ("xmark", .red)
        case .idle: return nil
        }
        return AnyView(
            Image(systemName: symbol)
                .font(.system(size: size * 0.09, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: size * 0.2, height: size * 0.2)
                .background(Circle().fill(color))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: max(1, size * 0.018)))
                .shadow(color: .black.opacity(0.25), radius: size * 0.015, y: size * 0.008)
        )
    }

    // MARK: Spear and tail

    /// The spear held at the body's right, drawn after the AgenLynk mark
    /// turned upside down without its outer frame: the inner bracket opens
    /// upward as the prongs, the blue bar is the point, and the mark's stem
    /// is the rod. Every part has the rod's thickness so it reads as one piece.
    private func spear(_ style: MascotStyle) -> some View {
        let tilt = 6.0
        let lean = tan(tilt * .pi / 180)
        let rodX = size * 0.37
        // Blue tip to rod end, centred on the body's right side.
        let top = -size * 0.44
        let bottom = size * 0.36
        let centerY = (top + bottom) / 2
        // The bracket is 56 + 11 of the mark's units across; the rod is 11.
        let width = size * 0.04 * 70 / 11
        return ZStack {
            SpearDrawing(lineWidth: max(1.5, size * 0.04))
                .frame(width: width, height: bottom - top)
                .shadow(color: .black.opacity(0.35), radius: size * 0.01, y: size * 0.006)
                .rotationEffect(.degrees(tilt))
                .offset(x: rodX, y: centerY)
            // A little nub of a hand gripping the rod.
            Ellipse()
                .fill(LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom))
                .overlay(Ellipse().fill(RadialGradient(colors: [Color.white.opacity(0.6), .clear, Color.black.opacity(0.15)],
                                                       center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.08)))
                .frame(width: size * 0.12, height: size * 0.1)
                .overlay(Ellipse().strokeBorder(Color.white.opacity(0.6), lineWidth: max(0.5, size * 0.008)))
                .shadow(color: .black.opacity(0.2), radius: size * 0.01, y: size * 0.006)
                .offset(x: rodX - lean * (size * 0.13 - centerY), y: size * 0.13)
        }
    }

    /// A thin tail curling out to the left, ending in a spade; it sways while
    /// the devil works.
    private func tail(_ style: MascotStyle, phase: Double) -> some View {
        let sway = mood == .working || mood == .waiting ? sin(phase * 4) * 8 : 0
        return ZStack {
            TailCurve()
                .stroke(style.horn, style: StrokeStyle(lineWidth: max(1.2, size * 0.035), lineCap: .round))
                .frame(width: size * 0.3, height: size * 0.3)
            Spade()
                .fill(LinearGradient(colors: [style.hornTip, style.horn], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.12, height: size * 0.12)
                .rotationEffect(.degrees(-40))
                .offset(x: -size * 0.15, y: -size * 0.14)
        }
        .rotationEffect(.degrees(sway), anchor: .bottomTrailing)
        .offset(x: -size * 0.35, y: size * 0.14)
    }
}

/// Mochi's body: a superellipse, wider than tall.
struct Squircle: InsettableShape {
    var exponent: CGFloat = 4
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        let a = rect.width / 2, b = rect.height / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        let steps = 120
        for step in 0...steps {
            let t = Double(step) / Double(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = CGFloat(copysign(pow(abs(c), 2 / Double(exponent)), c)) * a
            let y = CGFloat(copysign(pow(abs(s), 2 / Double(exponent)), s)) * b
            let point = CGPoint(x: center.x + x, y: center.y + y)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Squircle {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// The two curved eyes of a happy face.
private struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height))
        return path
    }
}

/// A short, slightly curved horn (drawn for the left side; flipped for the right).
private struct Horn: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY),
                          control: CGPoint(x: rect.minX - rect.width * 0.2, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX + rect.width * 0.25, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private struct TailCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.12),
                      control1: CGPoint(x: rect.minX, y: rect.maxY),
                      control2: CGPoint(x: rect.maxX * 0.7, y: rect.minY))
        return path
    }
}

/// The spade at the tail's tip.
private struct Spade: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY * 0.8), control: CGPoint(x: rect.maxX * 1.2, y: rect.maxY * 0.75))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY * 0.8))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: -rect.width * 0.2, y: rect.maxY * 0.75))
        path.closeSubpath()
        return path
    }
}

/// The spear upright in its frame: the AgenLynk mark turned upside down
/// without its outer frame, in the mark's own proportions (its design units:
/// strokes 11 wide, the inner bracket 56 across with 36-long arms, the blue
/// bar 48 long, the stem 68). The stem runs on as the rod, ends cut square
/// as in the mark. A collar binds the head to the rod, and every part has a
/// dark outline and is shaded as a metal bar lit from the top left.
private struct SpearDrawing: View {
    let lineWidth: CGFloat

    private typealias Metal = (base: Color, light: Color, dark: Color)
    private static let steel: Metal = (Color(white: 0.66), Color.white, Color(white: 0.24))
    private static let blue: Metal = (Color(red: 0.08, green: 0.38, blue: 0.98),
                                      Color(red: 0.62, green: 0.82, blue: 1),
                                      Color(red: 0.02, green: 0.16, blue: 0.55))

    var body: some View {
        Canvas { context, size in
            let unit = lineWidth / 11
            let midX = size.width / 2
            // The bracket's bar, measured down from the frame's top: the blue
            // bar rises 48 above it, the arms 36.
            let bar = 48 * unit + 9 * unit
            let halfSpan = 28 * unit
            let armTop = bar - 36 * unit
            let pointTop = bar - 48 * unit

            var rod = Path()
            rod.move(to: CGPoint(x: midX, y: bar))
            rod.addLine(to: CGPoint(x: midX, y: size.height - lineWidth))
            var prongs = Path()
            prongs.move(to: CGPoint(x: midX - halfSpan, y: armTop))
            prongs.addLine(to: CGPoint(x: midX - halfSpan, y: bar))
            prongs.addLine(to: CGPoint(x: midX + halfSpan, y: bar))
            prongs.addLine(to: CGPoint(x: midX + halfSpan, y: armTop))
            var point = Path()
            point.move(to: CGPoint(x: midX, y: pointTop))
            point.addLine(to: CGPoint(x: midX, y: bar))
            let collar = Path(roundedRect: CGRect(x: midX - lineWidth * 0.9, y: bar + lineWidth * 0.55,
                                                  width: lineWidth * 1.8, height: lineWidth * 0.9),
                              cornerRadius: lineWidth * 0.3)

            let outline = Color.black.opacity(0.5)
            let rim = lineWidth * 0.2
            // Outlines first, so the parts sit on one dark silhouette.
            context.stroke(rod, with: .color(outline),
                           style: StrokeStyle(lineWidth: lineWidth + rim * 2, lineCap: .round, lineJoin: .miter))
            context.stroke(prongs, with: .color(outline),
                           style: StrokeStyle(lineWidth: lineWidth + rim * 2, lineCap: .square, lineJoin: .miter))
            context.stroke(point, with: .color(outline), style: StrokeStyle(lineWidth: 10 * unit + rim * 2, lineCap: .square))
            context.stroke(collar, with: .color(outline), lineWidth: rim * 2)

            tube(rod, in: context, width: lineWidth, metal: Self.steel, cap: .butt)
            tube(prongs, in: context, width: lineWidth, metal: Self.steel, cap: .square)
            tube(point, in: context, width: 10 * unit, metal: Self.blue, cap: .square)
            solidFill(collar, in: context, metal: Self.steel)
            // The rod's foot, rounded.
            let foot = CGRect(x: midX - lineWidth / 2, y: size.height - lineWidth * 1.5, width: lineWidth, height: lineWidth)
            context.fill(Path(ellipseIn: foot), with: .color(Self.steel.base))
        }
    }

    /// A solid part lit like the bars: light on the left, shade on the right.
    private func solidFill(_ path: Path, in context: GraphicsContext, metal: Metal) {
        let box = path.boundingRect
        context.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: metal.light, location: 0),
                .init(color: metal.base, location: 0.45),
                .init(color: metal.dark, location: 1)
            ]),
            startPoint: CGPoint(x: box.minX, y: box.midY), endPoint: CGPoint(x: box.maxX, y: box.midY)
        ))
    }

    /// One bar drawn as a lit cylinder: its base color, a shaded band on the
    /// lower right and a bright band on the upper left, kept inside the bar so
    /// every part keeps its width.
    private func tube(_ path: Path, in context: GraphicsContext, width: CGFloat, metal: Metal, cap: CGLineCap) {
        let style = StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .miter)
        context.stroke(path, with: .color(metal.base), style: style)
        var inside = context
        inside.clip(to: path.strokedPath(style))
        inside.stroke(path.offsetBy(dx: width * 0.32, dy: width * 0.32), with: .color(metal.dark.opacity(0.6)),
                      style: StrokeStyle(lineWidth: width * 0.45, lineCap: .square, lineJoin: .miter))
        inside.stroke(path.offsetBy(dx: -width * 0.26, dy: -width * 0.26), with: .color(metal.light.opacity(0.85)),
                      style: StrokeStyle(lineWidth: width * 0.28, lineCap: .square, lineJoin: .miter))
    }
}

/// A small open smile: a gently curved top lip over a rounder bottom.
private struct OpenSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.25))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        path.closeSubpath()
        return path
    }
}

/// A rounded little fang: soft shoulders down to a blunt tip.
private struct Fang: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.maxY * 0.92),
                          control: CGPoint(x: rect.maxX, y: rect.maxY * 0.55))
        path.addQuadCurve(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.maxY * 0.92),
                          control: CGPoint(x: rect.midX, y: rect.maxY * 1.08))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.maxY * 0.55))
        path.closeSubpath()
        return path
    }
}

/// Each agent's take on Mochi's palette: a soft body gradient, ink for the
/// face, the pin its mark sits on, and horns and tail in its own color.
struct MascotStyle {
    let top: Color
    let bottom: Color
    let ink: Color
    let pin: Color
    let emblem: Color
    let horn: Color
    let hornTip: Color

    init(provider: String) {
        switch provider.lowercased() {
        case "claude":
            top = Color(red: 1.0, green: 0.93, blue: 0.87)
            bottom = Color(red: 0.93, green: 0.7, blue: 0.58)
            ink = Color(red: 0.24, green: 0.11, blue: 0.07)
            pin = Color(red: 0.85, green: 0.46, blue: 0.33)
            emblem = Color(red: 1.0, green: 0.96, blue: 0.92)
            horn = Color(red: 0.78, green: 0.36, blue: 0.24)
            hornTip = Color(red: 0.98, green: 0.62, blue: 0.46)
        case "codex":
            // Codex's blues, a little cooler than AgenLynk's own.
            top = Color(red: 0.91, green: 0.95, blue: 1.0)
            bottom = Color(red: 0.6, green: 0.73, blue: 0.97)
            ink = Color(red: 0.05, green: 0.09, blue: 0.24)
            pin = Color(white: 0.1)
            emblem = .white
            horn = Color(red: 0.16, green: 0.32, blue: 0.84)
            hornTip = Color(red: 0.45, green: 0.62, blue: 1.0)
        case "grok":
            top = Color(red: 0.93, green: 0.93, blue: 0.94)
            bottom = Color(red: 0.77, green: 0.77, blue: 0.79)
            ink = Color(red: 0.1, green: 0.08, blue: 0.07)
            pin = Color(white: 0.06)
            emblem = .white
            horn = Color(white: 0.3)
            hornTip = Color(white: 0.62)
        default:
            top = Color(red: 0.9, green: 0.95, blue: 1.0)
            bottom = Color(red: 0.6, green: 0.75, blue: 0.98)
            ink = Color(red: 0.06, green: 0.08, blue: 0.2)
            pin = Color(red: 0.08, green: 0.38, blue: 0.98)
            emblem = .white
            horn = Color(red: 0.06, green: 0.28, blue: 0.8)
            hornTip = Color(red: 0.4, green: 0.62, blue: 1.0)
        }
    }
}

/// The agent's own mark, simplified for a small badge.
public struct AgentEmblem: View {
    public let provider: String
    public var color: Color

    public init(provider: String, color: Color) {
        self.provider = provider
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            switch provider.lowercased() {
            case "claude":
                // A starburst of uneven rays.
                let lengths: [CGFloat] = [1, 0.78, 0.92, 0.7, 1, 0.84, 0.74, 0.96, 0.8, 0.9, 0.72, 0.88]
                for (index, length) in lengths.enumerated() {
                    let angle = Double(index) / Double(lengths.count) * 2 * .pi
                    var ray = Path()
                    ray.move(to: center)
                    ray.addLine(to: CGPoint(
                        x: center.x + CGFloat(cos(angle)) * side * 0.48 * length,
                        y: center.y + CGFloat(sin(angle)) * side * 0.48 * length
                    ))
                    context.stroke(ray, with: .color(color), style: StrokeStyle(lineWidth: side * 0.11, lineCap: .round))
                }
            case "codex":
                // A six-petal knot.
                for index in 0..<6 {
                    let petal = Path(roundedRect: CGRect(x: -side * 0.13, y: -side * 0.44, width: side * 0.26, height: side * 0.5), cornerRadius: side * 0.13)
                    let transform = CGAffineTransform(translationX: center.x, y: center.y)
                        .rotated(by: CGFloat(index) * .pi / 3)
                    context.stroke(petal.applying(transform), with: .color(color), lineWidth: side * 0.07)
                }
            case "grok":
                // An open ring cut by a slash.
                var ring = Path()
                ring.addArc(center: center, radius: side * 0.36, startAngle: .degrees(-20), endAngle: .degrees(250), clockwise: false)
                context.stroke(ring, with: .color(color), style: StrokeStyle(lineWidth: side * 0.1, lineCap: .round))
                var slash = Path()
                slash.move(to: CGPoint(x: center.x - side * 0.42, y: center.y + side * 0.42))
                slash.addLine(to: CGPoint(x: center.x + side * 0.42, y: center.y - side * 0.42))
                context.stroke(slash, with: .color(color), style: StrokeStyle(lineWidth: side * 0.11, lineCap: .round))
            default:
                var dot = Path()
                dot.addEllipse(in: CGRect(x: center.x - side * 0.3, y: center.y - side * 0.3, width: side * 0.6, height: side * 0.6))
                context.fill(dot, with: .color(color))
            }
        }
    }
}
