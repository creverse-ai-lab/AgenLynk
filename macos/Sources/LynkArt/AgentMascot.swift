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

/// AgenLynk's mascot, in one of two looks: a little devil (DevilMascot) or
/// a little mermaid (MermaidMascot). Both hold the AgenLynk trident and wear
/// the agent's mark and colors. Drawn in code so it scales from the notch
/// pill to a card and changes expression with the session.
public struct AgentMascot: View {
    public enum Mood: Equatable, Sendable {
        /// `awaiting`: its own turn sleeps until its Workers need it (Gateway
        /// 1.9 `waiting_tasks`), neither waiting for the person nor at rest.
        case idle, working, waiting, happy, failed, awaiting
    }

    public enum Kind: String, Equatable, Sendable {
        case devil, mermaid
    }

    public let provider: String
    public var size: CGFloat
    public var mood: Mood = .idle
    /// The AgenLynk spear in its hand; dropped at small sizes either way.
    public var holdsStaff = true
    public var kind: Kind = .mermaid
    /// Leaves out the resting motion (breathing, swaying, sagging), for a
    /// host that renders the mascot once as a still image.
    public var still = false
    /// Holds the mood's pose and moves nothing at all, not even in a turn:
    /// for a mascot that has had its moment (an alert after its first
    /// seconds). One moving 46pt mascot cost 14% CPU, a frozen one nothing.
    public var frozen = false

    public init(provider: String, size: CGFloat, mood: Mood = .idle, holdsStaff: Bool = true, kind: Kind = .mermaid, still: Bool = false, frozen: Bool = false) {
        self.provider = provider
        self.size = size
        self.mood = mood
        self.holdsStaff = holdsStaff
        self.kind = kind
        self.still = still
        self.frozen = frozen
    }

    public var body: some View {
        Group {
            switch kind {
            case .devil: DevilMascot(provider: provider, size: size, mood: mood, holdsStaff: holdsStaff, motion: !frozen)
            case .mermaid: MermaidMascot(provider: provider, size: size, mood: mood, holdsStaff: holdsStaff, motion: !frozen)
            }
        }
        // Outside a turn nothing inside moves: the whole mascot is one image
        // and the resting motion moves just that. In a turn its parts are
        // flattened one by one instead, so they can move on their own.
        .moving(frozen || !AgentMascot.moves(mood), WholeFlattened())
        .moving(!still && !frozen, RestingMotion(mood: mood))
    }

    /// Whether this mood moves the mascot's parts (bob, hop, sway, bubbles).
    static func moves(_ mood: Mood) -> Bool { mood == .working || mood == .waiting }

    static func label(_ provider: String) -> String {
        switch provider.lowercased() {
        case "claude": "Claude"
        case "codex": "Codex"
        case "grok": "Grok"
        default: "AgenLynk"
        }
    }
}

/// The little-mermaid look: a steamed bun (a domed top on a flat base) with
/// axolotl gills and a fish tail. Each agent has its own body colors, gills
/// and tail in its color, and its mark on the forehead.
struct MermaidMascot: View {
    let provider: String
    var size: CGFloat
    var mood: AgentMascot.Mood = .idle
    var holdsStaff = true
    /// False holds the mood's pose without moving (AgentMascot.frozen).
    var motion = true

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
            bubbles()
                .frame(width: size, height: size)
                .moving(animates, Flattened(margin: size * 0.05))
                .moving(animates, RiseMotion(active: true, distance: size * 0.06))
        }
        .frame(width: size, height: size)
        .moving(motion && mood == .waiting, CallingMotion())
        .moving(blinks, Blinking(shut: $eyesShut))
        .accessibilityLabel("\(AgentMascot.label(provider)) 봇")
    }


    private var bodyWidth: CGFloat { size * 0.72 }
    private var bodyHeight: CGFloat { size * 0.58 }
    private var animates: Bool { motion && (mood == .working || mood == .waiting) }
    // In a turn only, as before: a resting mascot is one still image.
    private var blinks: Bool { motion && mood == .working }
    @State private var eyesShut = false

    // MARK: Character

    private func character(_ style: MascotStyle, phase: Double) -> some View {
        let width = bodyWidth
        let height = bodyHeight
        return ZStack {
            if size >= 20 {
                // Axolotl gills, one tuft each side of the head: three
                // feathery fronds fanning up and out from a root tucked behind
                // the body, lit from the top left.
                ForEach([-1.0, 1.0], id: \.self) { side in
                    let length = width * 0.3
                    let thickness = width * 0.11
                    ZStack {
                        ForEach(Array([-48.0, -22.0, 4.0].enumerated()), id: \.offset) { index, angle in
                            ZStack {
                                LinearGradient(colors: [style.fin, style.finTip], startPoint: .leading, endPoint: .trailing)
                                LinearGradient(colors: [Color.white.opacity(0.4), .clear, Color.black.opacity(0.18)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                            .mask(GillFrond())
                            // The middle frond is the longest.
                            .frame(width: length * (index == 1 ? 1 : 0.86), height: thickness)
                            .shadow(color: .black.opacity(0.18), radius: width * 0.008, y: height * 0.008)
                            .offset(x: length * (index == 1 ? 1 : 0.86) / 2)
                            .rotationEffect(.degrees(angle), anchor: .center)
                        }
                    }
                    .frame(width: 0, height: 0)
                    .scaleEffect(x: side, y: 1)
                    .offset(x: side * width * 0.36, y: -height * 0.3)
                }
            }
            // The bun: solid, lit from the top, its face brightest in the
            // middle and rounding off to a slightly darker edge, like a soft
            // steamed bun. No outline or glassy rim, which read as see-through.
            Bun()
                .fill(LinearGradient(colors: [style.top, style.bottom], startPoint: .top, endPoint: .bottom))
            Bun()
                .fill(RadialGradient(stops: [
                    .init(color: Color.white.opacity(0.35), location: 0),
                    .init(color: .clear, location: 0.55),
                    .init(color: style.ink.opacity(0.16), location: 1)
                ], center: UnitPoint(x: 0.45, y: 0.45), startRadius: 0, endRadius: width * 0.62))
            face(style, width: width, height: height, phase: phase)
            if size >= 22 {
                // The agent's mark on the forehead: the
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
                    case .awaiting:
                        // Waiting on its Workers: eyes open, glancing up to
                        // the side where they work.
                        Capsule().fill(style.ink).frame(width: eyeWidth, height: eyeHeight * 0.85)
                            .overlay(catchlight(eyeWidth: eyeWidth, eyeHeight: eyeHeight * 0.85))
                            .offset(x: eyeWidth * 0.35, y: -eyeHeight * 0.25)
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

    /// A small open smile; none when it failed.
    @ViewBuilder
    private func mouth(_ style: MascotStyle, width: CGFloat, height: CGFloat) -> some View {
        if size >= 26 && mood == .idle {
            // Breathing slowly through a small round mouth.
            Ellipse()
                .fill(style.ink)
                .frame(width: width * 0.06, height: height * 0.05)
                .offset(y: height * 0.24)
        } else if size >= 26 && mood == .awaiting {
            // Patient: a small closed smile.
            SleepyEye()
                .stroke(style.ink, style: StrokeStyle(lineWidth: max(1, width * 0.022), lineCap: .round))
                .frame(width: width * 0.1, height: height * 0.035)
                .offset(y: height * 0.24)
        } else if size >= 26 && mood != .failed {
            OpenSmile()
                .fill(style.ink)
                .frame(width: width * 0.14, height: height * 0.1)
                .offset(y: height * 0.23)
        }
    }

    /// Mochi's speech-bubble badge: what the mermaid is up to.
    private var statusBadge: AnyView? {
        let (symbol, color): (String, Color)
        switch mood {
        case .working: (symbol, color) = ("ellipsis", Color(red: 0.23, green: 0.62, blue: 1))
        case .waiting: (symbol, color) = ("exclamationmark", .orange)
        case .happy: (symbol, color) = ("checkmark", .green)
        case .failed: (symbol, color) = ("xmark", .red)
        case .idle: (symbol, color) = ("zzz", Color(red: 0.42, green: 0.45, blue: 0.86))
        case .awaiting: (symbol, color) = ("hourglass", Color(red: 0.13, green: 0.68, blue: 0.62))
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

    /// A fish tail curling up behind the bun on the left, scaled, ending in
    /// a two-lobed fin; it sways while the mermaid works.
    private func tail(_ style: MascotStyle) -> some View {
        ZStack {
            ZStack {
                LinearGradient(colors: [style.finTip, style.fin], startPoint: .topLeading, endPoint: .bottomTrailing)
                Scales()
                    .stroke(Color.white.opacity(0.4), lineWidth: max(0.5, size * 0.006))
            }
            .mask(MermaidTail())
            .frame(width: size * 0.3, height: size * 0.3)
            ZStack {
                LinearGradient(colors: [style.finTip, style.fin], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [Color.white.opacity(0.4), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                FlukeRibs()
                    .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: max(0.5, size * 0.005), lineCap: .round))
            }
            .mask(Fluke())
            .frame(width: size * 0.22, height: size * 0.18)
            .rotationEffect(.degrees(-35))
            .offset(x: -size * 0.1, y: -size * 0.13)
        }
        .shadow(color: .black.opacity(0.22), radius: size * 0.012, y: size * 0.008)
        .moving(animates, Flattened(margin: size * 0.12))
        .moving(animates, SwayMotion(active: true, degrees: 7, anchor: .bottomTrailing))
        .offset(x: -size * 0.43, y: size * 0.2)
    }

    /// Bubbles rising by the head, drifting up while the mermaid works.
    @ViewBuilder
    private func bubbles() -> some View {
        if size >= 40 {
            ZStack {
                ForEach(Array([(0.0, 0.0, 0.07), (0.05, -0.1, 0.045), (-0.02, -0.18, 0.03)].enumerated()), id: \.offset) { _, bubble in
                    Circle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.05), Color.white.opacity(0.35)],
                                             center: .center, startRadius: 0, endRadius: size * bubble.2 * 0.5))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: max(0.5, size * 0.006)))
                        .overlay(Circle().fill(Color.white.opacity(0.9))
                            .frame(width: size * bubble.2 * 0.3, height: size * bubble.2 * 0.3)
                            .offset(x: -size * bubble.2 * 0.18, y: -size * bubble.2 * 0.18))
                        .frame(width: size * bubble.2, height: size * bubble.2)
                        .offset(x: size * bubble.0, y: size * bubble.1)
                }
            }
            .offset(x: -size * 0.4, y: -size * 0.25)
        }
    }
}

/// The slight motion a mascot keeps outside a turn, so it never looks
/// frozen: resting, it breathes (a slow swell, anchored at its base); done, it
/// sways a little; waiting on its Workers, it sways slowly; failed, it sags
/// slowly. A running or waiting mascot has its
/// own bob and hop instead. A repeating animation of the transform only: the
/// mascot itself is not redrawn, which keeps a row of resting mascots cheap.
struct RestingMotion: ViewModifier {
    let mood: AgentMascot.Mood
    @State private var phase = false

    func body(content: Content) -> some View {
        let (scaleX, scaleY, angle): (CGFloat, CGFloat, Double) = switch mood {
        case .idle: phase ? (0.992, 1.014, 0) : (1.004, 0.994, 0)
        case .happy: (1, 1, phase ? 2.5 : -2.5)
        // Waiting on its Workers: a slow, patient sway.
        case .awaiting: (1, 1, phase ? 3.5 : -3.5)
        case .failed: phase ? (1.01, 0.978, 0) : (1, 1, 0)
        case .working, .waiting: (1, 1, 0)
        }
        let period: Double = switch mood {
        case .idle: 1.9
        case .happy: 0.9
        case .awaiting: 2.4
        default: 2.6
        }
        content
            .scaleEffect(x: scaleX, y: scaleY, anchor: .bottom)
            .rotationEffect(.degrees(angle), anchor: .bottom)
            .animation(.easeInOut(duration: period).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

// MARK: Motion

// The mascots move by animating transforms of finished, flattened layers
// (offset, rotation), never by redrawing their gradients and shadows each
// frame. A repeating animation runs only while it shows: switching it off
// replaces it with a plain one, so an idle mascot costs nothing per frame.

/// Flattens a layer into one image, with room around it so nothing it draws
/// outside its frame (fins, horns, a fluke) is clipped.
struct Flattened: ViewModifier {
    let margin: CGFloat
    func body(content: Content) -> some View {
        content.padding(margin).drawingGroup().padding(-margin)
    }
}

/// The whole mascot as one image, as it rests. A plain drawingGroup: its own
/// frame already holds every part, and the padded variant (Flattened) under a
/// repeating transform made SwiftUI re-render it every frame.
struct WholeFlattened: ViewModifier {
    func body(content: Content) -> some View { content.drawingGroup() }
}

extension View {
    /// Applies a motion only while it runs. An idle motion modifier left in
    /// the tree (its state, its animation, its task) made SwiftUI redraw a
    /// resting mascot every frame under the resting motion: 20-33% CPU for
    /// one to five resting mascots instead of 3-5%.
    @ViewBuilder
    func moving<M: ViewModifier>(_ active: Bool, _ motion: M) -> some View {
        if active { modifier(motion) } else { self }
    }
}

/// The working blink, as a modifier so a resting mascot carries no task.
struct Blinking: ViewModifier {
    @Binding var shut: Bool
    func body(content: Content) -> some View {
        content.task { await Blink.run($shut) }
    }
}

/// The working bob and the waiting hop, for every layer that moves with the
/// body.
struct BobMotion: ViewModifier {
    let mood: AgentMascot.Mood
    let size: CGFloat
    @State private var up = false

    func body(content: Content) -> some View {
        let (offset, animation): (CGFloat, Animation?) = switch mood {
        case .working: (up ? -size * 0.022 : size * 0.022, .easeInOut(duration: 0.98).repeatForever(autoreverses: true))
        case .waiting: (up ? -size * 0.05 : 0, .easeOut(duration: 0.28).repeatForever(autoreverses: true))
        default: (0, nil)
        }
        content
            .offset(y: offset)
            .animation(animation ?? .default, value: up)
            .task(id: mood) { up = animation != nil }
    }
}

/// The waiting mascot rocks side to side about its base while it hops,
/// calling for the person, so a wait never reads as busy work.
struct CallingMotion: ViewModifier {
    @State private var left = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(left ? -5 : 5), anchor: .bottom)
            .animation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true), value: left)
            .task { left = true }
    }
}

/// A tail swaying about its root while the mascot works or waits.
struct SwayMotion: ViewModifier {
    let active: Bool
    let degrees: Double
    let anchor: UnitPoint
    @State private var right = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? (right ? degrees : -degrees) : 0), anchor: anchor)
            .animation(active ? .easeInOut(duration: 0.78).repeatForever(autoreverses: true) : .default, value: right)
            .task(id: active) { right = active }
    }
}

/// Bubbles drifting up and starting over, while the mascot works or waits.
struct RiseMotion: ViewModifier {
    let active: Bool
    let distance: CGFloat
    @State private var risen = false

    func body(content: Content) -> some View {
        content
            .offset(y: active && risen ? -distance : 0)
            .animation(active ? .linear(duration: 1.67).repeatForever(autoreverses: false) : .default, value: risen)
            .task(id: active) { risen = active }
    }
}

/// Whether the eyes are shut this instant: a short blink every few seconds,
/// two state changes per blink instead of a clock ticking every frame.
struct Blink {
    static func run(_ shut: Binding<Bool>) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_080_000_000)
            guard !Task.isCancelled else { return }
            shut.wrappedValue = true
            try? await Task.sleep(nanoseconds: 120_000_000)
            shut.wrappedValue = false
        }
    }
}

/// The body: a steamed bun, a dome on a flat base with softly rounded feet.
struct Bun: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let foot = h * 0.24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + foot, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - foot, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.maxY + h * 0.03))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - foot), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.maxX + w * 0.02, y: rect.minY + h * 0.2),
                      control2: CGPoint(x: rect.maxX - w * 0.17, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - foot),
                      control1: CGPoint(x: rect.minX + w * 0.17, y: rect.minY),
                      control2: CGPoint(x: rect.minX - w * 0.02, y: rect.minY + h * 0.2))
        path.addQuadCurve(to: CGPoint(x: rect.minX + foot, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The two curved eyes of a happy face.
/// A shut eye: a lid line curving down, as in sleep.
struct SleepyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY + rect.height))
        return path
    }
}

struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height))
        return path
    }
}

/// One axolotl gill frond, pointing right from a root at its left: a
/// tapered stalk with soft feathery bumps along both edges and a round tip.
private struct GillFrond: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let bumps = 3
        var path = Path()
        // Upper edge, root to tip, with bumps that shrink toward the tip.
        path.move(to: CGPoint(x: rect.minX, y: rect.midY - h * 0.22))
        for index in 0..<bumps {
            let from = CGFloat(index) / CGFloat(bumps)
            let to = CGFloat(index + 1) / CGFloat(bumps)
            let half = h * (0.24 - 0.12 * to)
            let mid = (from + to) / 2
            path.addQuadCurve(to: CGPoint(x: rect.minX + w * to * 0.88, y: rect.midY - half),
                              control: CGPoint(x: rect.minX + w * mid * 0.88, y: rect.midY - half - h * 0.32))
        }
        // The round tip.
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.88, y: rect.midY + h * 0.12),
                          control: CGPoint(x: rect.maxX + w * 0.04, y: rect.midY))
        // Lower edge, tip back to the root.
        for index in (0..<bumps).reversed() {
            let from = CGFloat(index + 1) / CGFloat(bumps)
            let to = CGFloat(index) / CGFloat(bumps)
            let half = h * (0.24 - 0.12 * to)
            let mid = (from + to) / 2
            path.addQuadCurve(to: CGPoint(x: rect.minX + w * to * 0.88, y: rect.midY + half),
                              control: CGPoint(x: rect.minX + w * mid * 0.88, y: rect.midY + half + h * 0.32))
        }
        path.closeSubpath()
        return path
    }
}

/// The tail: a band rooted at the bottom right, curling up and left to a
/// narrow end where the fluke sits.
private struct MermaidTail: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.45))
        path.addCurve(to: CGPoint(x: rect.minX + w * 0.2, y: rect.minY + h * 0.12),
                      control1: CGPoint(x: rect.minX + w * 0.55, y: rect.minY + h * 0.5),
                      control2: CGPoint(x: rect.minX + w * 0.28, y: rect.minY + h * 0.36))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.34, y: rect.minY + h * 0.2))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                      control1: CGPoint(x: rect.minX + w * 0.4, y: rect.minY + h * 0.7),
                      control2: CGPoint(x: rect.minX + w * 0.7, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Rows of scale arcs, masked to the tail.
private struct Scales: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width * 0.07
        var path = Path()
        var row = 0
        var y = rect.minY
        while y < rect.maxY + r {
            var x = rect.minX + (row.isMultiple(of: 2) ? 0 : r)
            while x < rect.maxX + r {
                path.move(to: CGPoint(x: x - r, y: y))
                path.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y + r * 1.6))
                x += r * 2
            }
            y += r * 1.1
            row += 1
        }
        return path
    }
}

/// The fluke: two lobes spreading up from a root at the bottom middle.
private struct Fluke: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.08), control: CGPoint(x: rect.minX, y: rect.minY + h * 0.75))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.42), control: CGPoint(x: rect.minX + w * 0.32, y: rect.minY + h * 0.1))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.08), control: CGPoint(x: rect.minX + w * 0.68, y: rect.minY + h * 0.1))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.minY + h * 0.75))
        path.closeSubpath()
        return path
    }
}

private struct FlukeRibs: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let root = CGPoint(x: rect.midX, y: rect.maxY * 0.92)
        var path = Path()
        for tip in [CGPoint(x: rect.minX + w * 0.15, y: rect.minY + h * 0.2),
                    CGPoint(x: rect.minX + w * 0.32, y: rect.minY + h * 0.28),
                    CGPoint(x: rect.minX + w * 0.68, y: rect.minY + h * 0.28),
                    CGPoint(x: rect.minX + w * 0.85, y: rect.minY + h * 0.2)] {
            path.move(to: root)
            path.addLine(to: tip)
        }
        return path
    }
}

/// The spear upright in its frame: the AgenLynk mark turned upside down
/// without its outer frame, in the mark's own proportions (its design units:
/// strokes 11 wide, the inner bracket 56 across with 36-long arms, the blue
/// bar 48 long, the stem 68). The stem runs on as the rod, ends cut square
/// as in the mark. A collar binds the head to the rod, and every part has a
/// dark outline and is shaded as a metal bar lit from the top left.
struct SpearDrawing: View {
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
struct OpenSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.25))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        path.closeSubpath()
        return path
    }
}

/// Each agent's take on Mochi's palette: a soft body gradient, ink for the
/// face, the pin its mark sits on, and fins and tail in its own color.
struct MascotStyle {
    let top: Color
    let bottom: Color
    let ink: Color
    let pin: Color
    let emblem: Color
    let fin: Color
    let finTip: Color

    init(provider: String) {
        switch provider.lowercased() {
        case "claude":
            top = Color(red: 1.0, green: 0.93, blue: 0.87)
            bottom = Color(red: 0.93, green: 0.7, blue: 0.58)
            ink = Color(red: 0.24, green: 0.11, blue: 0.07)
            pin = Color(red: 0.85, green: 0.46, blue: 0.33)
            emblem = Color(red: 1.0, green: 0.96, blue: 0.92)
            fin = Color(red: 0.78, green: 0.36, blue: 0.24)
            finTip = Color(red: 0.98, green: 0.62, blue: 0.46)
        case "codex":
            // Codex's blues, a little cooler than AgenLynk's own.
            top = Color(red: 0.91, green: 0.95, blue: 1.0)
            bottom = Color(red: 0.6, green: 0.73, blue: 0.97)
            ink = Color(red: 0.05, green: 0.09, blue: 0.24)
            pin = Color(white: 0.1)
            emblem = .white
            fin = Color(red: 0.16, green: 0.32, blue: 0.84)
            finTip = Color(red: 0.45, green: 0.62, blue: 1.0)
        case "grok":
            top = Color(red: 0.93, green: 0.93, blue: 0.94)
            bottom = Color(red: 0.77, green: 0.77, blue: 0.79)
            ink = Color(red: 0.1, green: 0.08, blue: 0.07)
            pin = Color(white: 0.06)
            emblem = .white
            fin = Color(white: 0.3)
            finTip = Color(white: 0.62)
        default:
            top = Color(red: 0.9, green: 0.95, blue: 1.0)
            bottom = Color(red: 0.6, green: 0.75, blue: 0.98)
            ink = Color(red: 0.06, green: 0.08, blue: 0.2)
            pin = Color(red: 0.08, green: 0.38, blue: 0.98)
            emblem = .white
            fin = Color(red: 0.06, green: 0.28, blue: 0.8)
            finTip = Color(red: 0.4, green: 0.62, blue: 1.0)
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
