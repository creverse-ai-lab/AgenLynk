import SwiftUI

/// The small companions that stand for a mascot's sub-agents: a bat (the
/// devil's sub-agent) with a fireball for its own sub-agent, or a fish (the
/// mermaid's) with a bubble. Drawn in the agent's colors. `beat` alternates
/// the motion pose (wings up or down, tail left or right, flame high or low)
/// so a host can animate from two cached images.
public struct AgentFamiliar: View {
    public enum Kind: String, Equatable, Sendable {
        case bat, fireball, fish, bubble
    }

    public let kind: Kind
    public let provider: String
    public var size: CGFloat
    public var beat = false

    public init(kind: Kind, provider: String, size: CGFloat, beat: Bool = false) {
        self.kind = kind
        self.provider = provider
        self.size = size
        self.beat = beat
    }

    /// What a sub-agent at `depth` (1 = a direct sub-agent) looks like next to
    /// a mascot of `mascot` kind; nil below the second level, which is not drawn.
    public static func kind(for mascot: AgentMascot.Kind, depth: Int) -> Kind? {
        switch (mascot, depth) {
        case (.devil, 1): .bat
        case (.devil, 2): .fireball
        case (.mermaid, 1): .fish
        case (.mermaid, 2): .bubble
        default: nil
        }
    }

    public var body: some View {
        let style = MascotStyle(provider: provider)
        ZStack {
            switch kind {
            case .bat: bat(style)
            case .fireball: fireball
            case .fish: fish(style)
            case .bubble: bubble
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(AgentMascot.label(provider)) 서브에이전트")
    }

    // MARK: Bat

    private func bat(_ style: MascotStyle) -> some View {
        let wing = LinearGradient(colors: [style.fin, style.finTip], startPoint: .top, endPoint: .bottom)
        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                ZStack {
                    BatWing()
                        .fill(wing)
                    // Finger bones fanning from the wrist to the scallop points.
                    BatWingBones()
                        .stroke(style.ink.opacity(0.45), style: StrokeStyle(lineWidth: max(0.5, size * 0.014), lineCap: .round))
                    BatWing().stroke(style.ink.opacity(0.4), lineWidth: max(0.5, size * 0.014))
                }
                .frame(width: size * 0.46, height: size * 0.4)
                // Wings beat about their root at the body, up then down.
                .rotationEffect(.degrees(beat ? 16 : -14), anchor: .leading)
                .scaleEffect(x: side, y: 1, anchor: .center)
                .offset(x: side * size * 0.25, y: -size * 0.04)
            }
            // Ears, outlined so they read against a raised wing of the same color.
            ForEach([-1.0, 1.0], id: \.self) { side in
                Triangle()
                    .fill(style.finTip)
                    .overlay(Triangle().stroke(style.ink.opacity(0.45), lineWidth: max(0.5, size * 0.012)))
                    .frame(width: size * 0.11, height: size * 0.15)
                    .rotationEffect(.degrees(side * 12))
                    .offset(x: side * size * 0.085, y: -size * 0.155)
            }
            Circle()
                .fill(RadialGradient(colors: [style.finTip, style.fin], center: UnitPoint(x: 0.4, y: 0.35),
                                     startRadius: 0, endRadius: size * 0.16))
                .frame(width: size * 0.3, height: size * 0.28)
            ForEach([-1.0, 1.0], id: \.self) { side in
                Circle()
                    .fill(Color.white)
                    .frame(width: size * 0.06, height: size * 0.06)
                    .offset(x: side * size * 0.055, y: -size * 0.02)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: size * 0.03, y: size * 0.02)
    }

    // MARK: Fireball

    private var fireball: some View {
        ZStack {
            Flame()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.2), Color(red: 1, green: 0.38, blue: 0.1),
                                              Color(red: 0.85, green: 0.15, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.62, height: size * (beat ? 0.86 : 0.8))
            Flame()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.98, blue: 0.75), Color(red: 1, green: 0.82, blue: 0.3)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.32, height: size * (beat ? 0.44 : 0.4))
                .offset(y: size * 0.16)
        }
        .offset(y: -size * 0.04)
        .shadow(color: Color(red: 1, green: 0.45, blue: 0.1).opacity(0.7), radius: size * 0.12)
    }

    // MARK: Fish

    private func fish(_ style: MascotStyle) -> some View {
        let scales = LinearGradient(colors: [style.finTip, style.fin], startPoint: .top, endPoint: .bottom)
        return ZStack {
            FishTail()
                .fill(scales)
                .frame(width: size * 0.3, height: size * 0.36)
                .rotationEffect(.degrees(beat ? 14 : -14), anchor: .trailing)
                .offset(x: -size * 0.3)
            Ellipse()
                .fill(scales)
                .overlay(Ellipse().fill(RadialGradient(colors: [Color.white.opacity(0.4), .clear],
                                                       center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.3)))
                .frame(width: size * 0.62, height: size * 0.42)
                .offset(x: size * 0.05)
            // A dorsal fin and a stripe.
            Triangle()
                .fill(style.fin)
                .frame(width: size * 0.18, height: size * 0.12)
                .offset(x: size * 0.02, y: -size * 0.24)
            Capsule()
                .fill(Color.white.opacity(0.55))
                .frame(width: size * 0.05, height: size * 0.3)
                .offset(x: -size * 0.08)
            Circle()
                .fill(style.ink)
                .overlay(Circle().fill(Color.white).frame(width: size * 0.03, height: size * 0.03).offset(x: -size * 0.01, y: -size * 0.01))
                .frame(width: size * 0.08, height: size * 0.08)
                .offset(x: size * 0.22, y: -size * 0.03)
        }
        .shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.02)
    }

    // MARK: Bubble

    private var bubble: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.white.opacity(0.05), Color.white.opacity(0.35)],
                                 center: .center, startRadius: 0, endRadius: size * 0.35))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: max(0.6, size * 0.05)))
            .overlay(Circle().fill(Color.white.opacity(0.9))
                .frame(width: size * 0.2, height: size * 0.2)
                .offset(x: -size * 0.13, y: -size * 0.13))
            .frame(width: size * (beat ? 0.72 : 0.66), height: size * (beat ? 0.66 : 0.72))
    }
}

/// A bat wing drawn for the right side, rooted at its left edge: the top
/// edge climbs from the body to the wrist and falls to the wing tip, and the
/// lower edge is cut in scallops between the finger tips.
private struct BatWing: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        var path = Path()
        path.move(to: point(0, 0.42))
        // Up to the wrist, then out to the tip.
        path.addQuadCurve(to: point(0.42, 0.04), control: point(0.12, 0.08))
        path.addQuadCurve(to: point(1, 0.3), control: point(0.74, 0.02))
        // Scallops back to the body: each dips up between two finger tips.
        let tips = [point(0.9, 0.86), point(0.6, 0.74), point(0.32, 0.86), point(0, 0.7)]
        var from = point(1, 0.3)
        for to in tips {
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            path.addQuadCurve(to: to, control: CGPoint(x: mid.x - w * 0.02, y: mid.y - h * 0.2))
            from = to
        }
        path.closeSubpath()
        return path
    }
}

/// The finger bones of `BatWing`: from the wrist to each finger tip.
private struct BatWingBones: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + w * x, y: rect.minY + h * y) }
        let wrist = point(0.42, 0.06)
        var path = Path()
        for tip in [point(0.9, 0.84), point(0.6, 0.72), point(0.32, 0.84)] {
            path.move(to: wrist)
            path.addLine(to: tip)
        }
        return path
    }
}

/// A flame: a round base rising to a point.
private struct Flame: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX + w * 0.15, y: rect.minY + h * 0.5),
                      control2: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.maxY),
                      control2: CGPoint(x: rect.minX - w * 0.15, y: rect.minY + h * 0.5))
        path.closeSubpath()
        return path
    }
}

/// A fish's tail, rooted at its right edge.
private struct FishTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.2))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.2))
        path.closeSubpath()
        return path
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
