import AppKit
import Combine
import Darwin
import SwiftUI

// MARK: - Model

private struct Snapshot: Decodable {
    let sessions: [AgentSession]
}

private struct PetStateEnvelope: Decodable {
    struct Agent: Decodable {
        let id: String
        let parentId: String?
        let role: String
        let provider: String
        let engine: String?
        let state: String
        let task: String?
        let updatedAt: String
    }

    let contract: String
    let version: String
    let sequence: Int
    let agents: [Agent]

    var isSupported: Bool {
        contract == "pet-state" && version.split(separator: ".").first == "1"
    }
}

private struct PetActionsEnvelope: Decodable {
    struct Action: Decodable {
        let id: String
        let action: String
    }

    let contract: String
    let version: String
    let sequence: Int
    let actions: [Action]

    var isSupported: Bool {
        contract == "pet-actions" && version.split(separator: ".").first == "1"
    }
}

private let contractTimestampFormatter = ISO8601DateFormatter()

private struct AgentSession: Decodable, Identifiable, Equatable {
    let provider: String
    let session: String
    let state: String
    let parent: String?
    let role: String?
    let engine: String?
    let time: TimeInterval?
    let commDirection: String?
    let inboxPending: Int?
    let cwd: String?
    let task: String?
    let tool: String?
    let delegated: Bool?
    var id: String { session }

    private enum CodingKeys: String, CodingKey {
        case provider, session, state, parent, role, engine, time, cwd, task, tool, delegated
        case commDirection = "comm_direction"
        case inboxPending = "inbox_pending"
    }

    init(
        provider: String,
        session: String,
        state: String,
        parent: String? = nil,
        role: String? = nil,
        engine: String? = nil,
        time: TimeInterval? = nil,
        commDirection: String? = nil,
        inboxPending: Int? = nil,
        cwd: String? = nil,
        task: String? = nil,
        tool: String? = nil,
        delegated: Bool? = nil
    ) {
        self.provider = provider
        self.session = session
        self.state = state
        self.parent = parent
        self.role = role
        self.engine = engine
        self.time = time
        self.commDirection = commDirection
        self.inboxPending = inboxPending
        self.cwd = cwd
        self.task = task
        self.tool = tool
        self.delegated = delegated
    }

    init(contractAgent agent: PetStateEnvelope.Agent, action: String?) {
        provider = agent.provider
        session = agent.id
        parent = agent.parentId
        role = agent.role
        engine = agent.engine
        time = contractTimestampFormatter.date(from: agent.updatedAt)?.timeIntervalSince1970
        inboxPending = nil
        cwd = nil
        task = agent.task
        tool = action == "useTool" ? "tool" : nil
        delegated = agent.role == "worker"

        switch action {
        case "waitForUser":
            state = "needs_input"
            commDirection = nil
        case "error":
            state = "blocked"
            commDirection = nil
        case "celebrate":
            state = "ready"
            commDirection = "inbound"
        case "disconnect":
            state = "offline"
            commDirection = nil
        case "sleep":
            state = "idle"
            commDirection = nil
        case "think", "useTool", "wake":
            state = "running"
            commDirection = nil
        default:
            commDirection = nil
            switch agent.state {
            case "starting", "running": state = "running"
            case "waiting": state = "needs_input"
            case "completed": state = "ready"
            case "failed": state = "blocked"
            case "offline": state = "offline"
            default: state = "idle"
            }
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider)
        session = try values.decode(String.self, forKey: .session)
        state = try values.decode(String.self, forKey: .state)
        parent = try values.decodeIfPresent(String.self, forKey: .parent)
        role = try values.decodeIfPresent(String.self, forKey: .role)
        engine = try values.decodeIfPresent(String.self, forKey: .engine)
        time = try values.decodeIfPresent(TimeInterval.self, forKey: .time)
        commDirection = try values.decodeIfPresent(String.self, forKey: .commDirection)
        inboxPending = try values.decodeIfPresent(Int.self, forKey: .inboxPending)
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
        task = try values.decodeIfPresent(String.self, forKey: .task)
        tool = try values.decodeIfPresent(String.self, forKey: .tool)
        delegated = try values.decodeIfPresent(Bool.self, forKey: .delegated)
    }
}

// MARK: - Tuning

private let windowSize = CGSize(width: 600, height: 600)
private let acpCompletionVisibility: TimeInterval = 2
private let readyLinger: TimeInterval = 5
private let arrowActivityWindow: TimeInterval = 2
private let coneHalfAngle: CGFloat = .pi / 6
private let firstRingDistance: CGFloat = 58
private let ringSpacing: CGFloat = 52
private let parkDistance: CGFloat = 30
private let rootMinGap: CGFloat = 46
private let minimumSpan: CGFloat = 2.4
private let edgeMargin: CGFloat = 90
private let parkArcStep: CGFloat = 0.35

private func shouldDisplayACP(_ session: AgentSession, now: TimeInterval) -> Bool {
    session.state != "offline" || now - (session.time ?? 0) <= acpCompletionVisibility
}

// Warm: the session is still connected but no data is flowing (idle, or ready
// past its linger). Offline means the connection is gone — it deliberately
// reuses the warm placement so the node keeps its spot while fadeFactor
// dissolves it over acpCompletionVisibility seconds.
private func isWarm(_ session: AgentSession, now: TimeInterval) -> Bool {
    switch session.state {
    case "idle", "offline":
        return true
    case "ready":
        return now - (session.time ?? 0) > readyLinger
    default:
        return false
    }
}

private func fadeFactor(_ session: AgentSession, now: TimeInterval) -> CGFloat {
    guard session.state == "offline" else { return 1 }
    return max(0, min(1, 1 - CGFloat((now - (session.time ?? now)) / acpCompletionVisibility)))
}

// MARK: - Layout (pure, testable)

private struct LayoutTarget: Equatable {
    let agent: AgentSession
    let angle: CGFloat
    let distance: CGFloat
    let depth: Int
    let warm: Bool
    let parentID: String?
}

private func layoutTargets(_ agents: [AgentSession], now: TimeInterval, span: CGFloat = 2 * .pi) -> [LayoutTarget] {
    let sorted = agents.sorted { $0.id < $1.id }
    let warmIDs = Set(sorted.filter { isWarm($0, now: now) }.map(\.id))

    // Warm sessions whose parent chain reaches a displayed session stay attached
    // to the tree; only unconnected warm sessions get parked behind the cursor.
    var treeIDs = Set(sorted.filter { !warmIDs.contains($0.id) || isFrontdoor($0) }.map(\.id))
    var grew = true
    while grew {
        grew = false
        for agent in sorted where warmIDs.contains(agent.id) && !treeIDs.contains(agent.id) {
            if let parent = agent.parent, treeIDs.contains(parent) {
                treeIDs.insert(agent.id)
                grew = true
            }
        }
    }
    let tree = sorted.filter { treeIDs.contains($0.id) }
    let parked = sorted.filter { !treeIDs.contains($0.id) }
    let children = Dictionary(
        grouping: tree.filter { $0.parent != nil && $0.parent != $0.id && treeIDs.contains($0.parent!) },
        by: { $0.parent! }
    )
    let roots = tree.filter { $0.parent == nil || $0.parent == $0.id || !treeIDs.contains($0.parent!) }

    var leafCache: [String: Int] = [:]
    var visiting = Set<String>()
    func leaves(_ id: String) -> Int {
        if let cached = leafCache[id] { return cached }
        guard visiting.insert(id).inserted else { return 1 }
        let kids = children[id] ?? []
        let count = kids.isEmpty ? 1 : kids.reduce(0) { $0 + leaves($1.id) }
        visiting.remove(id)
        leafCache[id] = count
        return count
    }

    // First ring grows with the root count so a circular layout never crowds.
    let ringRadius = max(firstRingDistance, CGFloat(roots.count) * rootMinGap / max(span, 0.1))

    var result: [LayoutTarget] = []
    var seen = Set<String>()
    func place(_ agent: AgentSession, lo: CGFloat, hi: CGFloat, depth: Int, parentID: String?) {
        guard seen.insert(agent.id).inserted else { return }
        let mid = (lo + hi) / 2
        result.append(LayoutTarget(
            agent: agent,
            angle: mid,
            distance: ringRadius + ringSpacing * CGFloat(depth),
            depth: depth,
            warm: warmIDs.contains(agent.id),
            parentID: parentID
        ))
        let kids = (children[agent.id] ?? []).sorted { $0.id < $1.id }
        guard !kids.isEmpty else { return }
        // Subtrees fan outward along the root's own direction, capped to a narrow cone.
        let fanLo = max(lo, mid - coneHalfAngle)
        let fanHi = min(hi, mid + coneHalfAngle)
        let total = CGFloat(kids.reduce(0) { $0 + leaves($1.id) })
        var cursor = fanLo
        for kid in kids {
            let share = (fanHi - fanLo) * CGFloat(leaves(kid.id)) / max(total, 1)
            place(kid, lo: cursor, hi: cursor + share, depth: depth + 1, parentID: agent.id)
            cursor += share
        }
    }

    let totalLeaves = CGFloat(roots.reduce(0) { $0 + leaves($1.id) })
    var cursor = -span / 2
    for root in roots {
        let share = span * CGFloat(leaves(root.id)) / max(totalLeaves, 1)
        place(root, lo: cursor, hi: cursor + share, depth: 0, parentID: nil)
        cursor += share
    }

    // Sessions trapped in a parent cycle are unreachable from any root; surface
    // them as roots instead of silently dropping them.
    let unplaced = tree.filter { !seen.contains($0.id) }
    for (index, agent) in unplaced.enumerated() {
        let offset = (CGFloat(index) - CGFloat(unplaced.count - 1) / 2) * parkArcStep
        place(agent, lo: offset, hi: offset, depth: 0, parentID: nil)
    }

    for (index, agent) in parked.enumerated() {
        let offset = (CGFloat(index) - CGFloat(parked.count - 1) / 2) * parkArcStep
        result.append(LayoutTarget(
            agent: agent,
            angle: .pi + offset,
            distance: parkDistance,
            depth: 0,
            warm: true,
            parentID: nil
        ))
    }
    return result
}

// MARK: - Edge semantics (pure, testable)

private enum EdgeMode: Equatable {
    case flowingToChild
    case flowingToParent
    case paused
    case still
    case hidden
}

// A session earns the heartbeat only when the HUMAN must respond. Delegated
// (gateway-owned) sessions are approved by their orchestrator agent, so they
// only get the calm orange ring and paused arrow.
private func demandsAttention(_ agent: AgentSession) -> Bool {
    (agent.state == "needs_input" || agent.state == "blocked") && agent.delegated != true
}

private func isFrontdoor(_ agent: AgentSession) -> Bool {
    agent.role == "frontdoor"
}

private func edgeMode(for agent: AgentSession, now: TimeInterval) -> EdgeMode {
    switch agent.state {
    case "needs_input", "blocked":
        return .paused
    case "ready":
        return now - (agent.time ?? 0) <= readyLinger ? .flowingToParent : .hidden
    case "running":
        let declared = agent.commDirection?.lowercased()
        let inbound = declared == "inbound" || declared == "upstream" || declared == "return"
        let recent = now - (agent.time ?? 0) <= arrowActivityWindow
        if recent { return inbound ? .flowingToParent : .flowingToChild }
        return .still
    default:
        return .hidden
    }
}

// MARK: - Status store

private final class StatusStore: ObservableObject {
    @Published var sessions: [AgentSession] = []
    private let stateURL: URL
    private let actionsURL: URL?
    private let agentStateDirectory: URL
    private var timer: Timer?

    init() {
        let path = ProcessInfo.processInfo.environment["PET_STATE_FILE"]
            ?? FileManager.default.currentDirectoryPath + "/.pet-codex-app-state.json"
        let actionsPath = ProcessInfo.processInfo.environment["PET_ACTIONS_FILE"]
        let agentPath = ProcessInfo.processInfo.environment["PET_AGENT_STATE_DIR"]
            ?? FileManager.default.currentDirectoryPath + "/.pet-agent-states"
        stateURL = URL(fileURLWithPath: path)
        actionsURL = actionsPath.map { URL(fileURLWithPath: $0) }
        agentStateDirectory = URL(fileURLWithPath: agentPath)
        refresh()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func refresh() {
        var latest: [String: AgentSession] = [:]
        let now = Date().timeIntervalSince1970
        if let stateData = try? Data(contentsOf: stateURL),
           let actionsURL,
           let actionsData = try? Data(contentsOf: actionsURL),
           let state = try? JSONDecoder().decode(PetStateEnvelope.self, from: stateData),
           let actions = try? JSONDecoder().decode(PetActionsEnvelope.self, from: actionsData),
           state.isSupported,
           actions.isSupported,
           state.sequence == actions.sequence {
            let actionByID = actions.actions.reduce(into: [String: String]()) { result, item in
                result[item.id] = item.action
            }
            for agent in state.agents {
                let session = AgentSession(contractAgent: agent, action: actionByID[agent.id])
                if shouldDisplayACP(session, now: now) { latest[session.id] = session }
            }
        } else if let data = try? Data(contentsOf: stateURL),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            // Legacy fallback for direct development use outside Lynk.
            for session in snapshot.sessions where shouldDisplayACP(session, now: now) {
                latest[session.id] = session
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: agentStateDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let session = try? JSONDecoder().decode(AgentSession.self, from: data) {
                if shouldDisplayACP(session, now: now) {
                    latest[session.id] = session
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        let next = latest.values.sorted { $0.id < $1.id }
        if sessions != next { sessions = next }
    }
}

// MARK: - Render frame

private struct RenderNode: Identifiable {
    let agent: AgentSession
    let point: CGPoint
    let size: CGFloat
    let opacity: CGFloat
    let labelOpacity: CGFloat
    let warm: Bool
    var id: String { agent.id }
}

private struct RenderEdge: Identifiable {
    let id: String
    let from: CGPoint
    let to: CGPoint
    let mode: EdgeMode
    let dashed: Bool
}

private struct RenderFrame {
    var nodes: [RenderNode] = []
    var edges: [RenderEdge] = []
    var anchor: CGPoint = .zero
    var badgeOpacity: CGFloat = 0
    var edgeOpacity: CGFloat = 1
    var activeCount = 0
    var warmCount = 0
    var needsAttention = false
    var time: TimeInterval = 0
}

// MARK: - Motion controller (springs, collapse, edge-aware opening)

private final class MotionController: ObservableObject {
    @Published var frame = RenderFrame()

    private struct Motion { var x, y, vx, vy: CGFloat }

    private let store: StatusStore
    private let window: NSWindow
    private var timer: Timer?
    private var motions: [String: Motion] = [:]
    private var hub: Motion?
    private var openAngle: CGFloat = .pi / 2
    private var spread: CGFloat = 1
    private var lastTick: TimeInterval?
    private var lastSessions: [AgentSession] = []
    private var lastMousePoint: NSPoint?
    private var restTicks = 0

    init(store: StatusStore) {
        self.store = store
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: TreeFlowScene(controller: self))
        window.orderFrontRegardless()

        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let clock = Date().timeIntervalSinceReferenceDate
        let dt = CGFloat(min(0.033, lastTick.map { clock - $0 } ?? 1.0 / 60.0))
        lastTick = clock
        let now = Date().timeIntervalSince1970

        let mouse = NSEvent.mouseLocation
        let mouseMoved = lastMousePoint.map { hypot(mouse.x - $0.x, mouse.y - $0.y) > 0.5 } ?? true
        lastMousePoint = mouse
        let sessions = store.sessions
        let sessionsChanged = sessions != lastSessions
        lastSessions = sessions
        let screenFrame = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: windowSize)

        // Follow the mouse only up to a margin inside the screen: at the edges the
        // graph stops and stays fully visible instead of riding off with the cursor.
        let followX = min(max(mouse.x, screenFrame.minX + edgeMargin), max(screenFrame.minX + edgeMargin, screenFrame.maxX - edgeMargin))
        let followY = min(max(mouse.y, screenFrame.minY + edgeMargin), max(screenFrame.minY + edgeMargin, screenFrame.maxY - edgeMargin))
        var hub = self.hub ?? Motion(x: followX, y: followY, vx: 0, vy: 0)
        hub.vx += (120 * (followX - hub.x) - 11 * hub.vx) * dt
        hub.vy += (120 * (followY - hub.y) - 11 * hub.vy) * dt
        hub.x += hub.vx * dt
        hub.y += hub.vy * dt
        self.hub = hub

        let speed = hypot(hub.vx, hub.vy)
        let spreadTarget = max(0, min(1, 1 - (speed - 70) / 260))
        spread += (spreadTarget - spread) * min(1, dt * 5)
        let spreadOp = max(0, min(1, (spread - 0.3) / 0.5))

        // Open toward the roomiest direction: the screen center. Near the middle the
        // layout is a full circle; near edges it narrows to an arc facing inward.
        let dxs = screenFrame.midX - hub.x
        let dys = screenFrame.midY - hub.y
        if hypot(dxs, dys) > 50 {
            let target = atan2(-dys, dxs)
            var diff = target - openAngle
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            openAngle += diff * min(1, dt * 4)
        }
        let edgeDistance = min(
            hub.x - screenFrame.minX,
            screenFrame.maxX - hub.x,
            hub.y - screenFrame.minY,
            screenFrame.maxY - hub.y
        )
        let proximity = max(0, min(1, 1 - edgeDistance / 320))
        let span = 2 * .pi - proximity * (2 * .pi - minimumSpan)

        var origin = NSPoint(x: hub.x - windowSize.width / 2, y: hub.y - windowSize.height / 2)
        origin.x = min(max(origin.x, screenFrame.minX), max(screenFrame.minX, screenFrame.maxX - windowSize.width))
        origin.y = min(max(origin.y, screenFrame.minY), max(screenFrame.minY, screenFrame.maxY - windowSize.height))
        window.setFrameOrigin(origin)
        let anchor = CGPoint(x: hub.x - origin.x, y: windowSize.height - (hub.y - origin.y))

        let targets = layoutTargets(sessions, now: now, span: span)
        var ids = Set<String>()
        var points: [String: CGPoint] = [:]
        var sizes: [String: CGFloat] = [:]
        var nodes: [RenderNode] = []
        var maxNodeSpeed: CGFloat = 0
        for target in targets {
            ids.insert(target.agent.id)
            let angle = openAngle + target.angle
            let dist = target.distance * spread
            let goal = CGPoint(x: anchor.x + cos(angle) * dist, y: anchor.y + sin(angle) * dist)
            var motion = motions[target.agent.id] ?? Motion(x: anchor.x, y: anchor.y, vx: 0, vy: 0)
            motion.vx += (170 * (goal.x - motion.x) - 13 * motion.vx) * dt
            motion.vy += (170 * (goal.y - motion.y) - 13 * motion.vy) * dt
            motion.x += motion.vx * dt
            motion.y += motion.vy * dt
            motions[target.agent.id] = motion
            maxNodeSpeed = max(maxNodeSpeed, hypot(motion.vx, motion.vy))

            let point = CGPoint(x: motion.x, y: motion.y)
            let baseSize: CGFloat = isFrontdoor(target.agent)
                ? (target.warm ? 20 : 30)
                : target.warm ? 14 : max(16, 26 - CGFloat(target.depth) * 4)
            let size = baseSize * (0.55 + 0.45 * spread)
            points[target.agent.id] = point
            sizes[target.agent.id] = size
            let fade = fadeFactor(target.agent, now: now)
            nodes.append(RenderNode(
                agent: target.agent,
                point: point,
                size: size,
                opacity: (0.25 + 0.75 * spreadOp) * (target.warm ? 0.5 : 1) * fade,
                labelOpacity: (target.warm ? (target.parentID != nil ? spreadOp * 0.45 : 0) : spreadOp) * fade,
                warm: target.warm
            ))
        }
        motions = motions.filter { ids.contains($0.key) }

        var edges: [RenderEdge] = []
        for target in targets {
            guard let parentID = target.parentID,
                  let from = points[parentID],
                  let to = points[target.agent.id] else { continue }
            let trimFrom = (sizes[parentID] ?? 30) / 2 + 4
            let trimTo = (sizes[target.agent.id] ?? 24) / 2 + 4
            let dx = to.x - from.x, dy = to.y - from.y
            let length = hypot(dx, dy)
            guard length > trimFrom + trimTo + 10 else { continue }
            edges.append(RenderEdge(
                id: target.agent.id,
                from: CGPoint(x: from.x + dx / length * trimFrom, y: from.y + dy / length * trimFrom),
                to: CGPoint(x: to.x - dx / length * trimTo, y: to.y - dy / length * trimTo),
                mode: target.warm ? .hidden : edgeMode(for: target.agent, now: now),
                dashed: target.warm
            ))
        }

        var next = RenderFrame()
        next.nodes = nodes
        next.edges = edges
        next.anchor = anchor
        next.badgeOpacity = 1 - spreadOp
        next.edgeOpacity = spreadOp
        next.activeCount = targets.filter { !$0.warm }.count
        next.warmCount = targets.count - next.activeCount
        next.needsAttention = targets.contains { !$0.warm && demandsAttention($0.agent) }
        next.time = clock

        // Motion = information, applied to CPU too: once everything is visually
        // still (no spinning/flowing/pulsing/fading, springs settled, mouse and
        // sessions unchanged) stop publishing frames so SwiftUI goes quiet.
        let hasLiveMotion = targets.contains {
            !$0.warm && ($0.agent.state == "running" || demandsAttention($0.agent))
        }
            || targets.contains { $0.agent.state == "offline" }
            || edges.contains { $0.mode == .flowingToChild || $0.mode == .flowingToParent || $0.mode == .paused }
        let animating = sessionsChanged || mouseMoved || hasLiveMotion
            || speed > 2 || maxNodeSpeed > 2 || abs(spreadTarget - spread) > 0.01
        if animating {
            restTicks = 0
        } else {
            restTicks += 1
            if restTicks > 30 { return }
        }
        frame = next
    }
}

// MARK: - Drawing

// Lub-dub heartbeat: two sharp bumps per ~0.9s cycle, 0...1.
private func heartbeat(_ time: TimeInterval) -> CGFloat {
    let phase = CGFloat(time.truncatingRemainder(dividingBy: 0.9) / 0.9)
    func bump(_ center: CGFloat, _ width: CGFloat) -> CGFloat {
        let offset = (phase - center) / width
        return max(0, 1 - offset * offset)
    }
    return min(1, bump(0.14, 0.1) + 0.62 * bump(0.36, 0.11))
}

private func arrowPath(at point: CGPoint, angle: CGFloat) -> Path {
    let c = cos(angle), s = sin(angle)
    func corner(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: point.x + x * c - y * s, y: point.y + x * s + y * c)
    }
    var path = Path()
    path.move(to: corner(6, 0))
    path.addLine(to: corner(-5, -4.5))
    path.addLine(to: corner(-5, 4.5))
    path.closeSubpath()
    return path
}

private func brandColor(_ provider: String) -> Color {
    switch provider.lowercased() {
    case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "grok": return .black
    case "codex", "chatgpt": return .white
    default: return .gray
    }
}

private func stateColor(_ state: String) -> Color {
    switch state {
    case "running": return .cyan
    case "needs_input": return .orange
    case "blocked": return .red
    case "ready": return .green
    default: return .gray
    }
}

/// Artwork bundle, resolved for the layout this binary actually ships in.
///
/// SwiftPM's generated `Bundle.module` looks beside `Bundle.main.bundleURL`
/// and then at an absolute path from the machine that built it — inside
/// `LynkPet.app` the first misses (resources live in `Contents/Resources`) and
/// the second only exists on a developer's own Mac, so `Bundle.module` traps
/// on any other machine. Resolve it here instead, and return nil rather than
/// trapping: missing artwork must degrade to a plain node, never kill the Pet.
let petResourceBundle: Bundle? = {
    let bundleName = "ACPMonitor_LynkPet.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(bundleName),
        // `swift run` and the test harness leave it beside the executable.
        Bundle.main.bundleURL.appendingPathComponent(bundleName),
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName)
    ]
    for case let url? in candidates {
        if let bundle = Bundle(url: url) { return bundle }
    }
    return nil
}()

let providerLogoNames = ["codex": "chatgpt", "chatgpt": "chatgpt", "claude": "claude", "grok": "grok"]

private let providerLogos: [String: NSImage] = {
    providerLogoNames.compactMapValues { name in
        guard let url = petResourceBundle?.url(forResource: name, withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }
}()

private func logoForProvider(_ provider: String) -> NSImage? {
    providerLogos[provider.lowercased()]
}

private struct AgentNodeView: View {
    let node: RenderNode
    let time: TimeInterval

    // One line only: the repo (top folder of the session's cwd), falling back to
    // the task snippet, then the engine name so multiple instances stay tellable.
    private var label: String {
        let prefix = isFrontdoor(node.agent) ? "Frontdoor · " : ""
        if let cwd = node.agent.cwd, !cwd.isEmpty {
            return prefix + URL(fileURLWithPath: cwd).lastPathComponent
        }
        if let task = node.agent.task, !task.isEmpty { return prefix + task }
        let raw = node.agent.engine ?? node.agent.provider
        return prefix + String(raw.replacingOccurrences(of: "gpt-", with: "").prefix(12))
    }

    var body: some View {
        let size = node.size
        let pulsing = demandsAttention(node.agent) && !node.warm
        let spinning = node.agent.state == "running" && !node.warm
        let ringColor = node.warm ? Color.gray : stateColor(node.agent.state)
        ZStack {
            if pulsing {
                let phase = CGFloat((time * 0.8).truncatingRemainder(dividingBy: 1))
                Circle()
                    .stroke(Color.orange.opacity(Double(1 - phase) * 0.6), lineWidth: 1.5)
                    .frame(width: size + phase * 28, height: size + phase * 28)
            }
            Circle().fill(brandColor(node.agent.provider))
            if let logo = logoForProvider(node.agent.provider) {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .scaleEffect(1.2)
                    .clipShape(Circle())
                    .rotationEffect(.radians(spinning ? time.truncatingRemainder(dividingBy: 2 * .pi / 1.8) * 1.8 : 0))
            } else {
                Text(node.agent.provider.prefix(1).uppercased())
                    .font(.system(size: size * 0.42, weight: .black))
                    .foregroundStyle(.white)
                    .rotationEffect(.radians(spinning ? time.truncatingRemainder(dividingBy: 2 * .pi / 1.8) * 1.8 : 0))
            }
            Circle()
                .stroke(ringColor, lineWidth: pulsing ? 2.5 + heartbeat(time) * 2 : 2.5)
            if isFrontdoor(node.agent) {
                Circle()
                    .stroke(.white.opacity(0.85), lineWidth: 1.2)
                    .frame(width: size + 7, height: size + 7)
                Text("F")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 14, height: 14)
                    .background(.cyan, in: Circle())
                    .offset(x: -size * 0.38, y: -size * 0.38)
            }
            if let pending = node.agent.inboxPending, pending > 0, !node.warm {
                Text("\(pending)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.purple, in: Circle())
                    .offset(x: size * 0.38, y: size * 0.38)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(pulsing ? 1 + 0.3 * heartbeat(time) : 1)
        .overlay {
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(maxWidth: 92)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: size / 2 + 10)
                .opacity(node.labelOpacity)
        }
        .opacity(node.opacity)
        .accessibilityLabel("\(isFrontdoor(node.agent) ? "frontdoor " : "")\(node.agent.provider) \(label) \(node.agent.state)")
    }
}

private struct BadgeView: View {
    let active: Int
    let warm: Int
    let attention: Bool
    let time: TimeInterval

    var body: some View {
        let beat = attention ? 1 + 0.3 * heartbeat(time) : 1
        ZStack {
            Circle().fill(.black.opacity(0.55))
            Circle().stroke(attention ? .orange : .cyan, lineWidth: 2)
            Text("\(active)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
            if warm > 0 {
                ZStack {
                    Circle().fill(.black.opacity(0.55))
                    Circle().stroke(.gray, lineWidth: 1.5)
                    Text("\(warm)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(width: 14, height: 14)
                .offset(x: -12, y: 10)
            }
        }
        .frame(width: 22, height: 22)
        .scaleEffect(beat)
    }
}

private struct TreeFlowScene: View {
    @ObservedObject var controller: MotionController

    var body: some View {
        let frame = controller.frame
        ZStack {
            Canvas { context, _ in
                for edge in frame.edges {
                    drawEdge(edge, time: frame.time, opacity: frame.edgeOpacity, in: &context)
                }
            }
            ForEach(frame.nodes) { node in
                AgentNodeView(node: node, time: frame.time)
                    .position(node.point)
            }
            if frame.badgeOpacity > 0.02 {
                BadgeView(
                    active: frame.activeCount,
                    warm: frame.warmCount,
                    attention: frame.needsAttention,
                    time: frame.time
                )
                .position(frame.anchor)
                .opacity(frame.badgeOpacity)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height)
    }

    private func drawEdge(_ edge: RenderEdge, time: TimeInterval, opacity: CGFloat, in context: inout GraphicsContext) {
        guard opacity > 0.02 else { return }
        var line = Path()
        line.move(to: edge.from)
        line.addLine(to: edge.to)
        if edge.dashed {
            context.stroke(
                line,
                with: .color(.white.opacity(0.18 * opacity)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
            )
        } else {
            context.stroke(line, with: .color(.white.opacity(0.26 * opacity)), lineWidth: 1.2)
        }

        let dx = edge.to.x - edge.from.x
        let dy = edge.to.y - edge.from.y
        let angle = atan2(dy, dx)

        func arrow(_ u: CGFloat, color: Color, alpha: CGFloat, reversed: Bool) {
            let point = CGPoint(x: edge.from.x + dx * u, y: edge.from.y + dy * u)
            let path = arrowPath(at: point, angle: reversed ? angle + .pi : angle)
            context.fill(path, with: .color(color.opacity(Double(alpha * opacity))))
        }

        switch edge.mode {
        case .flowingToChild:
            for index in 0..<2 {
                let u = CGFloat((time * 0.45 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1))
                arrow(u, color: .cyan, alpha: 1, reversed: false)
            }
        case .flowingToParent:
            for index in 0..<2 {
                let u = CGFloat((time * 0.45 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1))
                arrow(1 - u, color: .green, alpha: 1, reversed: true)
            }
        case .paused:
            let u = 0.82 + CGFloat(sin(time * 3)) * 0.02
            let alpha = 0.6 + 0.4 * CGFloat((sin(time * 4) + 1) / 2)
            arrow(u, color: .orange, alpha: alpha, reversed: false)
        case .still:
            arrow(0.55, color: .cyan, alpha: 0.5, reversed: false)
        case .hidden:
            break
        }
    }
}

// MARK: - Self test

/// Fails the self-test in release builds too. `assert` is compiled out under
/// `-O`, which is exactly how this binary ships, so anything the release gate
/// must actually catch has to be checked with this instead.
private func require(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "check failed",
    line: UInt = #line
) {
    guard condition else {
        fputs("LynkPet self-test failed at line \(line): \(message())\n", stderr)
        exit(1)
    }
}

/// Proves the shipped app can find its own artwork. This is the check that was
/// missing when `Bundle.module` silently resolved through the build machine's
/// absolute path and the Pet then trapped on every other Mac.
private func verifyBundledResources() {
    require(petResourceBundle != nil, "resource bundle not found next to \(Bundle.main.bundleURL.path)")
    for name in Set(providerLogoNames.values).sorted() {
        let url = petResourceBundle?.url(forResource: name, withExtension: "jpg")
        require(url != nil, "missing artwork \(name).jpg in \(petResourceBundle?.bundlePath ?? "-")")
        require(NSImage(contentsOf: url!) != nil, "unreadable artwork \(name).jpg")
    }
}

private func selfTest() {
    verifyBundledResources()
    let now = Date().timeIntervalSince1970
    let stateJSON = #"{"contract":"pet-state","version":"1.0.0","sequence":7,"agents":[{"id":"frontdoor-1","parentId":null,"role":"frontdoor","provider":"codex","engine":"codex","state":"waiting","task":"Approve","updatedAt":"2026-08-10T12:34:55.000Z","source":"gateway"},{"id":"worker-1","parentId":"frontdoor-1","role":"worker","provider":"claude","engine":"sonnet","state":"running","task":"Implement","updatedAt":"2026-08-10T12:34:55.000Z","source":"gateway"}]}"#
    let actionsJSON = #"{"contract":"pet-actions","version":"1.0.0","sequence":7,"actions":[{"id":"frontdoor-1","parentId":null,"action":"waitForUser"},{"id":"worker-1","parentId":"frontdoor-1","action":"useTool"}]}"#
    let contractState = try! JSONDecoder().decode(PetStateEnvelope.self, from: Data(stateJSON.utf8))
    let contractActions = try! JSONDecoder().decode(PetActionsEnvelope.self, from: Data(actionsJSON.utf8))
    require(contractState.isSupported && contractActions.isSupported && contractState.sequence == contractActions.sequence)
    let actionByID = Dictionary(uniqueKeysWithValues: contractActions.actions.map { ($0.id, $0.action) })
    let contractSessions = contractState.agents.map { AgentSession(contractAgent: $0, action: actionByID[$0.id]) }
    require(contractSessions.first { $0.id == "frontdoor-1" }?.state == "needs_input")
    require(contractSessions.first { $0.id == "frontdoor-1" }?.delegated == false)
    require(contractSessions.first { $0.id == "worker-1" }?.state == "running")
    require(contractSessions.first { $0.id == "worker-1" }?.delegated == true)

    let root1 = AgentSession(provider: "codex", session: "a-root", state: "running", time: now)
    let frontdoor = AgentSession(provider: "codex", session: "frontdoor", state: "running", role: "frontdoor", time: now)
    let root2 = AgentSession(provider: "codex", session: "b-root", state: "running", time: now)
    let child = AgentSession(provider: "claude", session: "c-child", state: "running", parent: "a-root", time: now)
    let frontdoorChild = AgentSession(provider: "claude", session: "frontdoor-child", state: "running", parent: "frontdoor", time: now)
    let grand = AgentSession(provider: "grok", session: "d-grand", state: "running", parent: "c-child", time: now)
    let idle = AgentSession(provider: "claude", session: "e-idle", state: "idle", time: now)
    let doneOld = AgentSession(provider: "grok", session: "f-done", state: "ready", time: now - 10)
    let doneNew = AgentSession(provider: "grok", session: "g-done", state: "ready", time: now)

    require(!isWarm(root1, now: now))
    require(isFrontdoor(frontdoor))
    require(!isFrontdoor(root1))
    let frontdoorTree = layoutTargets([frontdoor, frontdoorChild], now: now)
    require(frontdoorTree.first { $0.agent.id == "frontdoor-child" }?.depth == 1)
    let warmFrontdoor = AgentSession(provider: "codex", session: "warm-frontdoor", state: "idle", role: "frontdoor", time: now)
    let warmFrontdoorChild = AgentSession(provider: "claude", session: "warm-frontdoor-child", state: "idle", parent: "warm-frontdoor", time: now)
    let warmFrontdoorTree = layoutTargets([warmFrontdoor, warmFrontdoorChild], now: now)
    require(warmFrontdoorTree.first { $0.agent.id == "warm-frontdoor" }?.parentID == nil)
    require(warmFrontdoorTree.first { $0.agent.id == "warm-frontdoor-child" }?.parentID == "warm-frontdoor")
    require(isWarm(idle, now: now))
    require(isWarm(doneOld, now: now))
    require(!isWarm(doneNew, now: now))

    let targets = layoutTargets([root1, root2, child, grand, idle, doneOld], now: now)
    let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.agent.id, $0) })
    require(abs(byID["a-root"]!.angle) <= .pi + 0.001)
    require(abs(byID["b-root"]!.angle) <= .pi + 0.001)
    require(byID["a-root"]!.angle != byID["b-root"]!.angle)
    require(byID["c-child"]!.depth == 1 && byID["d-grand"]!.depth == 2)
    require(byID["d-grand"]!.distance > byID["c-child"]!.distance)
    require(byID["c-child"]!.distance > byID["a-root"]!.distance)
    require(byID["c-child"]!.parentID == "a-root")
    require(abs(byID["c-child"]!.angle - byID["a-root"]!.angle) <= coneHalfAngle + 0.001)
    require(abs(byID["d-grand"]!.angle - byID["c-child"]!.angle) <= coneHalfAngle + 0.001)
    require(byID["e-idle"]!.warm && abs(byID["e-idle"]!.angle - .pi) < 1)
    require(byID["f-done"]!.warm && byID["f-done"]!.distance == parkDistance)

    // Narrow span (near a screen edge) keeps roots inside the arc.
    let narrow = layoutTargets([root1, root2, child, grand], now: now, span: 1.0)
    require(narrow.filter { $0.depth == 0 }.allSatisfy { abs($0.angle) <= 0.5 + 0.001 })

    // A crowded first ring pushes outward instead of overlapping.
    let many = (0..<12).map { AgentSession(provider: "codex", session: "m-\($0)", state: "running", time: now) }
    let ring = layoutTargets(many, now: now)
    require(ring.first!.distance > firstRingDistance)
    require(Set(ring.map(\.angle)).count == ring.count)

    // Self-parented and cyclic sessions must still be placed, never dropped or hung.
    let selfParent = AgentSession(provider: "codex", session: "s-self", state: "running", parent: "s-self", time: now)
    let selfTargets = layoutTargets([selfParent], now: now)
    require(selfTargets.count == 1 && selfTargets[0].depth == 0 && selfTargets[0].parentID == nil)
    let cycleA = AgentSession(provider: "codex", session: "p-a", state: "running", parent: "q-b", time: now)
    let cycleB = AgentSession(provider: "claude", session: "q-b", state: "running", parent: "p-a", time: now)
    let cycleTargets = layoutTargets([cycleA, cycleB], now: now)
    require(cycleTargets.count == 2)

    let orphan = AgentSession(provider: "claude", session: "h-orphan", state: "running", parent: "e-idle", time: now)
    let orphanTargets = layoutTargets([idle, orphan], now: now)
    let placedOrphan = orphanTargets.first { $0.agent.id == "h-orphan" }!
    require(placedOrphan.depth == 0 && placedOrphan.parentID == nil && !placedOrphan.warm)

    // A warm session with a displayed parent stays attached to the tree instead of parking.
    let warmChild = AgentSession(provider: "claude", session: "i-warm", state: "idle", parent: "a-root", time: now)
    let warmGrand = AgentSession(provider: "grok", session: "j-warm", state: "idle", parent: "i-warm", time: now)
    let connected = layoutTargets([root1, warmChild, warmGrand], now: now)
    let placedWarm = connected.first { $0.agent.id == "i-warm" }!
    let placedGrandWarm = connected.first { $0.agent.id == "j-warm" }!
    require(placedWarm.warm && placedWarm.parentID == "a-root" && placedWarm.depth == 1)
    require(abs(placedWarm.angle) <= coneHalfAngle + 0.001)
    require(placedGrandWarm.warm && placedGrandWarm.parentID == "i-warm" && placedGrandWarm.depth == 2)

    require(edgeMode(for: child, now: now) == .flowingToChild)
    require(edgeMode(for: AgentSession(provider: "claude", session: "x", state: "running", time: now - 5), now: now) == .still)
    require(edgeMode(for: AgentSession(provider: "grok", session: "y", state: "needs_input", time: now), now: now) == .paused)
    require(edgeMode(for: doneNew, now: now) == .flowingToParent)
    require(edgeMode(for: doneOld, now: now) == .hidden)
    let inbound = AgentSession(provider: "grok", session: "z", state: "running", time: now, commDirection: "inbound")
    require(edgeMode(for: inbound, now: now) == .flowingToParent)

    // Heartbeat only when the human must respond, never for delegated sessions.
    let userWaiting = AgentSession(provider: "codex", session: "u", state: "needs_input", time: now)
    let agentWaiting = AgentSession(provider: "grok", session: "v", state: "needs_input", time: now, delegated: true)
    require(demandsAttention(userWaiting))
    require(!demandsAttention(agentWaiting))
    require(!demandsAttention(root1))

    let recentOffline = AgentSession(provider: "grok", session: "recent", state: "offline", parent: "main", engine: "grok", time: 100)
    require(shouldDisplayACP(recentOffline, now: 101))
    require(!shouldDisplayACP(recentOffline, now: 103))
    require(fadeFactor(recentOffline, now: 100) == 1)
    require(fadeFactor(recentOffline, now: 101) == 0.5)
    require(fadeFactor(recentOffline, now: 103) == 0)
    require(fadeFactor(root1, now: now) == 1)
}

// MARK: - App bootstrap

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: StatusStore?
    private var controller: MotionController?
    private var parentWatchdog: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = StatusStore()
        self.store = store
        controller = MotionController(store: store)
        if let value = ProcessInfo.processInfo.environment["PET_PARENT_PID"],
           let parentPID = Int32(value), parentPID > 0 {
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                if kill(parentPID, 0) == -1 && errno == ESRCH { NSApp.terminate(nil) }
            }
            parentWatchdog = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

private var instanceLockFD: Int32 = -1

private func acquireInstanceLock(timeout: TimeInterval = 2.5) -> Bool {
    let statePath = ProcessInfo.processInfo.environment["PET_STATE_FILE"]
        ?? FileManager.default.currentDirectoryPath + "/.pet-codex-app-state.json"
    let lockPath = statePath + ".overlay.lock"
    let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return false }
    let deadline = Date().addingTimeInterval(timeout)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        guard Date() < deadline else {
            close(descriptor)
            return false
        }
        usleep(50_000)
    }
    instanceLockFD = descriptor
    return true
}

let app = NSApplication.shared
private let delegate = AppDelegate()
if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if !acquireInstanceLock() {
    fputs("CodexPet is already running for this state file.\n", stderr)
} else {
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
