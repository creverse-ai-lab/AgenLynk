import AppKit
import SwiftUI
/// The little-devil look of AgenLynk's mascot (see AgentMascot): a cute
/// little devil with Mochi's soft squircle body (after Coucou), horns and a
/// spade tail, holding a spear whose head is the
/// AgenLynk mark. Each agent has its own: body colors, horns and tail in the
/// agent's color, and its mark on the forehead. Drawn in code so it scales
/// from the notch pill to a card and changes expression with the session.
struct DevilMascot: View {
    let provider: String
    var size: CGFloat
    var mood: AgentMascot.Mood = .idle
    /// The AgenLynk spear in its hand; dropped at small sizes either way.
    var holdsStaff = true

    var body: some View {
        let style = MascotStyle(provider: provider)
        // Each part is flattened once and moved by a transform animation (see
        // Motion): nothing here is redrawn frame by frame.
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.3))
                .frame(width: bodyWidth * 0.8, height: size * 0.07)
                .blur(radius: size * 0.025)
                .offset(y: size * 0.4)
                .frame(width: size, height: size)
                .moving(animates, Flattened(margin: size * 0.05))
            if size >= 26 {
                tail(style)
                    .moving(animates, BobMotion(mood: mood, size: size))
            }
            if holdsStaff && size >= 30 {
                spear(style)
                    // Its offsets reach beyond its own small frame: flattened
                    // in that frame, the spear was cut away while it moved.
                    .frame(width: size, height: size)
                    .moving(animates, Flattened(margin: size * 0.1))
            }
            character(style, phase: 0)
                .moving(animates, Flattened(margin: size * 0.3))
                .moving(animates, BobMotion(mood: mood, size: size))
        }
        .frame(width: size, height: size)
        .moving(mood == .waiting, CallingMotion())
        .moving(blinks, Blinking(shut: $eyesShut))
        .accessibilityLabel("\(AgentMascot.label(provider)) 봇")
    }

    private var bodyWidth: CGFloat { size * 0.72 }
    private var bodyHeight: CGFloat { size * 0.56 }
    private var animates: Bool { mood == .working || mood == .waiting }
    // In a turn only, as before: a resting mascot is one still image.
    private var blinks: Bool { mood == .working }
    @State private var eyesShut = false

    // MARK: Character

    private func character(_ style: MascotStyle, phase: Double) -> some View {
        let width = bodyWidth
        let height = bodyHeight
        return ZStack {
            if size >= 20 {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    ZStack {
                        LinearGradient(colors: [style.finTip, style.fin], startPoint: .top, endPoint: .bottom)
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
        let blink = blinks && eyesShut ? 0.15 : 1.0
        let eyeY = height * (mood == .waiting ? 0.0 : 0.05)
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Group {
                    switch mood {
                    case .happy:
                        HappyEye()
                            .stroke(style.ink, style: StrokeStyle(lineWidth: eyeWidth * 0.7, lineCap: .round))
                            .frame(width: eyeWidth * 2, height: eyeHeight * 0.4)
                    case .idle:
                        // Asleep: lids shut, curving down.
                        SleepyEye()
                            .stroke(style.ink, style: StrokeStyle(lineWidth: eyeWidth * 0.6, lineCap: .round))
                            .frame(width: eyeWidth * 1.9, height: eyeHeight * 0.3)
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
        if size >= 26 && mood == .idle {
            // Asleep: a small round mouth, the fang tucked away.
            Ellipse()
                .fill(style.ink)
                .frame(width: width * 0.06, height: height * 0.05)
                .offset(y: height * 0.24)
        } else if size >= 26 && mood != .failed {
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
        case .idle: (symbol, color) = ("zzz", Color(red: 0.42, green: 0.45, blue: 0.86))
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
    private func tail(_ style: MascotStyle) -> some View {
        ZStack {
            TailCurve()
                .stroke(style.fin, style: StrokeStyle(lineWidth: max(1.2, size * 0.035), lineCap: .round))
                .frame(width: size * 0.3, height: size * 0.3)
            Spade()
                .fill(LinearGradient(colors: [style.finTip, style.fin], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.12, height: size * 0.12)
                .rotationEffect(.degrees(-40))
                .offset(x: -size * 0.15, y: -size * 0.14)
        }
        .moving(animates, Flattened(margin: size * 0.12))
        .moving(animates, SwayMotion(active: true, degrees: 8, anchor: .bottomTrailing))
        .offset(x: -size * 0.35, y: size * 0.14)
    }
}

/// Mochi's body: a superellipse, wider than tall.
private struct Squircle: InsettableShape {
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
