import ACPShared
import SwiftUI

/// The dashboard's 그래프 view: the delegation tree as a static node-link
/// drawing (GraphLayout). Fixed node size, both-axis scrolling, no motion:
/// status shows as a dot and a tint, never as animation. Clicking a node
/// selects its session, like a sequence lane header. Resting Workers that
/// connect no moving one sit in a folded "대기 중 Worker N개" box below.
struct DashboardGraphView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    let graph: DashboardGraph
    let selectedFrontdoorId: String?
    let selectedSessionId: String?
    var emptyState = SequenceEmptyState()
    let selectFrontdoor: (String) -> Void
    let selectSession: (_ frontdoorId: String?, _ sessionId: String) -> Void
    @State private var renamingSession: GatewaySession?

    private var layout: GraphLayout { graph.layout }

    var body: some View {
        if layout.isEmpty {
            ContentUnavailableView {
                Label(emptyState.title, systemImage: emptyState.symbol)
            } description: {
                Text(emptyState.description)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        drawing
                            // A small tree sits in the corner without scrolling;
                            // a big one scrolls both ways at the same node size.
                            .frame(
                                width: max(layout.width, proxy.size.width),
                                height: max(layout.height, proxy.size.height),
                                alignment: .topLeading
                            )
                    }
                }
                if graph.restingCount > 0 {
                    restingBox
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .sheet(item: $renamingSession) { session in
                SessionRenameSheet(session: session)
            }
        }
    }

    private var drawing: some View {
        let positions = Dictionary(layout.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ZStack(alignment: .topLeading) {
            ForEach(layout.edges) { edge in
                if let from = positions[edge.from], let to = positions[edge.to] {
                    edgePath(from: from, to: to)
                        .stroke(edgeColor(to), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            .accessibilityHidden(true)

            if layout.groups.count > 1 {
                ForEach(layout.groups) { group in
                    if let frontdoor = graph.frontdoors[group.id] {
                        groupLabel(frontdoor)
                            .offset(x: layout.metrics.padding, y: group.y)
                    }
                }
            }

            ForEach(layout.nodes) { node in
                if let session = graph.sessions[node.id] {
                    nodeButton(node, session: session)
                        .offset(x: node.x, y: node.y)
                }
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("세션 호출 그래프. Frontdoor와 Worker의 호출 관계")
    }

    /// Parent's right edge to child's left edge, a gentle S between columns.
    private func edgePath(from: GraphLayout.Node, to: GraphLayout.Node) -> Path {
        let metrics = layout.metrics
        let start = CGPoint(x: from.x + metrics.nodeWidth, y: from.y + metrics.nodeHeight / 2)
        let end = CGPoint(x: to.x, y: to.y + metrics.nodeHeight / 2)
        let bend = (end.x - start.x) / 2
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + bend, y: start.y),
            control2: CGPoint(x: end.x - bend, y: end.y)
        )
        return path
    }

    /// Calls into a moving Worker carry its status color, faintly; the rest
    /// stay neutral.
    private func edgeColor(_ child: GraphLayout.Node) -> Color {
        guard let session = graph.sessions[child.id],
              MenuBarPipeline.Urgency(status: session.status) <= .running,
              session.status != "cancelling" else {
            return Color(nsColor: .separatorColor)
        }
        return statusColor(session.status).opacity(0.55)
    }

    private func groupLabel(_ frontdoor: FrontdoorSession) -> some View {
        let name = settings.frontdoorName(id: frontdoor.id, auto: frontdoor.displayName)
        return Button { selectFrontdoor(frontdoor.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.stack").font(.caption2).foregroundStyle(.secondary)
                Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(frontdoor.statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor(frontdoor.statusKey))
                    .lineLimit(1)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(frontdoor.id == selectedFrontdoorId ? Color.accentColor : Color.primary)
        .help("클릭해 이 Frontdoor 선택")
        .accessibilityLabel("\(name), \(frontdoor.statusText)")
    }

    private func nodeButton(_ node: GraphLayout.Node, session: GatewaySession) -> some View {
        let name = settings.stepName(session)
        let role = sessionRoleLabel(session, depth: node.depth)
        let status = sessionStatusLabel(session.status)
        return Button {
            selectSession(graph.frontdoors[node.groupId]?.id, session.sessionId)
        } label: {
            GraphNodeView(
                session: session,
                name: name,
                selected: session.sessionId == selectedSessionId,
                // An idle parent kept only to connect a moving Worker.
                dimmed: node.depth > 0 && !session.isFrontdoorRecord && !MenuBarPipeline.isMoving(session),
                width: layout.metrics.nodeWidth,
                height: layout.metrics.nodeHeight
            )
        }
        .buttonStyle(.plain)
        .help(nodeHelp(session, name: name, role: role, status: status))
        .accessibilityLabel("\(role), \(name), \(status)")
        .contextMenu {
            Button("세션 상세 열기") { openWindow(id: "session-detail", value: session.sessionId) }
            Button("이름 바꾸기…") { renamingSession = session }
        }
    }

    /// Resting Workers left out of the tree, folded by default; open, a
    /// grid of chips per tree (labelled when there are several).
    private var restingBox: some View {
        let open = settings.showRestingGraphWorkers
        let count = graph.restingCount
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                settings.showRestingGraphWorkers.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 12)
                    Image(systemName: "moon.zzz").font(.caption2)
                    Text("대기 중 Worker \(count)개").font(.caption)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(open ? "대기 중 Worker 접기" : "대기 중 Worker \(count)개 펼치기")
            .accessibilityLabel(open ? "대기 중 Worker 접기" : "대기 중 Worker \(count)개 펼치기")
            if open {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(graph.resting) { group in
                            if graph.resting.count > 1, let frontdoor = graph.frontdoors[group.id] {
                                Text(settings.frontdoorName(id: frontdoor.id, auto: frontdoor.displayName))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                                      alignment: .leading, spacing: 6) {
                                ForEach(group.nodes, id: \.id) { input in
                                    if let session = graph.sessions[input.id] {
                                        restingChip(session, depth: input.depth, groupId: group.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .restingBox()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("대기 중 Worker \(count)개")
    }

    private func restingChip(_ session: GatewaySession, depth: Int, groupId: String) -> some View {
        let name = settings.stepName(session)
        let role = sessionRoleLabel(session, depth: depth)
        let status = sessionStatusLabel(session.status)
        let selected = session.sessionId == selectedSessionId
        var help = nodeHelp(session, name: name, role: role, status: status)
        if graph.resting.count > 1, let frontdoor = graph.frontdoors[groupId] {
            help = "Frontdoor: \(settings.frontdoorName(id: frontdoor.id, auto: frontdoor.displayName))\n" + help
        }
        return Button {
            selectSession(graph.frontdoors[groupId]?.id, session.sessionId)
        } label: {
            HStack(spacing: 5) {
                ProviderIcon(provider: session.provider, size: 12)
                Text(name).font(.caption2).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor(session.status))
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 1.5 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(role), \(name), \(status)")
        .contextMenu {
            Button("세션 상세 열기") { openWindow(id: "session-detail", value: session.sessionId) }
            Button("이름 바꾸기…") { renamingSession = session }
        }
    }

    private func nodeHelp(_ session: GatewaySession, name: String, role: String, status: String) -> String {
        var lines = ["\(role) · \(name)", "상태: \(status)"]
        if let total = session.usage?.total { lines.append("세션 누적 토큰 \(formatTokenCount(total))") }
        if let model = session.model { lines.append("모델: \(model)") }
        lines.append("세션 id: \(session.sessionId)")
        lines.append("클릭해 이 세션 선택 · 우클릭으로 이름 바꾸기")
        return lines.joined(separator: "\n")
    }
}

/// A compact node: provider, name, status dot and word, tokens.
private struct GraphNodeView: View {
    let session: GatewaySession
    let name: String
    let selected: Bool
    var dimmed = false
    let width: Double
    let height: Double

    var body: some View {
        HStack(spacing: 7) {
            ProviderIcon(provider: session.provider, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(session.isFrontdoorRecord ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(sessionStatusLabel(session.status))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(color)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let total = session.usage?.total {
                        Text(formatTokenCount(total))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: height, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : borderColor, lineWidth: selected ? 2 : 1)
        )
        .opacity(dimmed && !selected ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        session.status == "cancelling" ? .secondary : statusColor(session.status)
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.12) }
        if session.isWaitingForUser { return Color.orange.opacity(0.10) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if session.isWaitingForUser { return Color.orange.opacity(0.5) }
        if session.isFrontdoorRecord { return providerColor(session.provider).opacity(0.45) }
        return Color(nsColor: .separatorColor)
    }
}
