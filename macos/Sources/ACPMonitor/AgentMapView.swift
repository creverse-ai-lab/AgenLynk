import SwiftUI

struct AgentMapView: View {
    let sessions: [GatewaySession]
    let inbox: [MonitorRecord]

    var body: some View {
        GeometryReader { geometry in
            let snapshot = PetSnapshot.make(sessions: sessions, inbox: inbox)
            let layout = AgentMapLayout.make(snapshot.sessions, minimumWidth: geometry.size.width - 28)
            ScrollView([.horizontal, .vertical]) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    AgentMapCanvas(
                        layout: layout,
                        phase: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
                .frame(width: layout.width, height: max(layout.height, geometry.size.height - 28))
                .padding(14)
            }
        }
    }
}

private struct AgentMapNode: Identifiable {
    let agent: PetSnapshot.Session
    let point: CGPoint
    var id: String { agent.session }
}

private struct AgentMapEdge: Identifiable {
    let parent: CGPoint
    let child: CGPoint
    let state: String
    let id: String
}

private struct AgentMapLayout {
    let nodes: [AgentMapNode]
    let edges: [AgentMapEdge]
    let width: Double
    let height: Double

    static func make(_ agents: [PetSnapshot.Session], minimumWidth: Double) -> AgentMapLayout {
        let roots = agents.filter { $0.parent == nil }.sorted { $0.session < $1.session }
        let children = Dictionary(grouping: agents.filter { $0.parent != nil }, by: { $0.parent! })
        let columns = max(1, min(3, Int(ceil(sqrt(Double(max(roots.count, 1)))))))
        let cellWidth = 390.0
        let cellHeight = 330.0
        let rows = max(1, Int(ceil(Double(max(roots.count, 1)) / Double(columns))))
        let width = max(minimumWidth, Double(columns) * cellWidth)
        let height = Double(rows) * cellHeight
        let xOffset = max(0, (width - Double(columns) * cellWidth) / 2)
        var nodes: [AgentMapNode] = []
        var edges: [AgentMapEdge] = []

        for (index, root) in roots.enumerated() {
            let column = index % columns
            let row = index / columns
            let center = CGPoint(
                x: xOffset + Double(column) * cellWidth + cellWidth / 2,
                y: Double(row) * cellHeight + cellHeight / 2
            )
            nodes.append(AgentMapNode(agent: root, point: center))
            let workers = (children[root.session] ?? []).sorted { $0.session < $1.session }
            for (workerIndex, worker) in workers.enumerated() {
                let ring = workerIndex / 8
                let indexInRing = workerIndex % 8
                let ringCount = min(8, workers.count - ring * 8)
                let angle = -Double.pi / 2 + 2 * Double.pi * Double(indexInRing) / Double(max(ringCount, 1))
                let radius = 108.0 + Double(ring) * 62.0
                let point = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
                nodes.append(AgentMapNode(agent: worker, point: point))
                edges.append(AgentMapEdge(parent: center, child: point, state: worker.state, id: worker.session))
            }
        }

        let placed = Set(nodes.map(\.id))
        let orphans = agents.filter { !placed.contains($0.session) }
        for (index, orphan) in orphans.enumerated() {
            let point = CGPoint(x: 110 + Double(index % 6) * 150, y: height - 45)
            nodes.append(AgentMapNode(agent: orphan, point: point))
        }
        return AgentMapLayout(nodes: nodes, edges: edges, width: width, height: height)
    }
}

private struct AgentMapCanvas: View {
    let layout: AgentMapLayout
    let phase: TimeInterval

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in layout.edges {
                    var line = Path()
                    line.move(to: edge.parent)
                    line.addLine(to: edge.child)
                    context.stroke(
                        line,
                        with: .color(mapStateColor(edge.state).opacity(0.42)),
                        style: StrokeStyle(lineWidth: 1.6, dash: edge.state == "idle" ? [5, 5] : [])
                    )
                    if edge.state == "running" {
                        let progress = phase.truncatingRemainder(dividingBy: 1.4) / 1.4
                        let point = CGPoint(
                            x: edge.parent.x + (edge.child.x - edge.parent.x) * progress,
                            y: edge.parent.y + (edge.child.y - edge.parent.y) * progress
                        )
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.cyan))
                    }
                }
            }
            ForEach(layout.nodes) { node in
                AgentMapNodeView(node: node, phase: phase)
                    .position(node.point)
            }
            if layout.nodes.isEmpty {
                ContentUnavailableView(
                    "현재 진행 중인 Agent가 없습니다",
                    systemImage: "circle.grid.cross",
                    description: Text("ACP 또는 로컬 Frontdoor가 작업을 시작하면 현재 실행 중인 관계가 표시됩니다.")
                )
                .frame(width: layout.width, height: layout.height)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ACP와 로컬 Agent 상태 맵")
    }
}

private struct AgentMapNodeView: View {
    let node: AgentMapNode
    let phase: TimeInterval

    private var isFrontdoor: Bool { node.agent.role == "frontdoor" }
    private var pulse: Double {
        guard node.agent.state == "running" else { return 1 }
        return 1 + 0.05 * (sin(phase * 4) + 1) / 2
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(providerColor(node.agent.provider).opacity(0.18))
                Image(systemName: isFrontdoor ? "person.crop.circle.badge.checkmark" : "sparkles")
                    .foregroundStyle(providerColor(node.agent.provider))
            }
            .frame(width: isFrontdoor ? 34 : 28, height: isFrontdoor ? 34 : 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(node.agent.source == "local" ? "LOCAL" : "ACP")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(node.agent.source == "local" ? .purple : .blue)
                    Text(isFrontdoor ? node.agent.provider.capitalized : node.agent.provider)
                        .font(isFrontdoor ? .callout.weight(.bold) : .caption.weight(.semibold))
                        .lineLimit(1)
                }
                Text(node.agent.task ?? node.agent.engine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if node.agent.inboxPending > 0 {
                Text("\(node.agent.inboxPending)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.orange, in: Circle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: isFrontdoor ? 154 : 132)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isFrontdoor ? 16 : 12))
        .overlay(RoundedRectangle(cornerRadius: isFrontdoor ? 16 : 12).stroke(mapStateColor(node.agent.state), lineWidth: isFrontdoor ? 2.4 : 1.7))
        .shadow(color: mapStateColor(node.agent.state).opacity(0.25), radius: 8)
        .scaleEffect(pulse)
        .help([node.agent.engine, node.agent.cwd, node.agent.task].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel("\(node.agent.provider) \(node.agent.role ?? "agent") \(node.agent.state)")
    }
}

private func mapStateColor(_ state: String) -> Color {
    switch state {
    case "running": .cyan
    case "ready", "idle": .green
    case "needs_input": .orange
    case "blocked": .red
    case "offline": .gray
    default: .secondary
    }
}
