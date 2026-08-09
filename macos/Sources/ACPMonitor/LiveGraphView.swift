import SwiftUI

struct LiveGraphView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let isMap = settings.monitorViewMode == "map"
        let realtimeSessions = model.realtimeSessions
        let projection: GraphProjection? = isMap ? nil : GraphProjection.make(
            sessions: realtimeSessions,
            eventsBySession: model.eventsBySession,
            windowMinutes: 1,
            currentTurnsOnly: true
        )
        let frontdoorCount = projection?.groups.count
            ?? Set(realtimeSessions.compactMap(\.openerInstanceId)).count
        let workerCount = projection?.workerLaneCount
            ?? realtimeSessions.filter { !$0.isFrontdoorRecord }.count
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ACPLogoLockup(subtitle: "실시간 Agent 흐름 · ACP + Local")
                Label(liveStatusText, systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(liveStatusColor)
                Text("\(frontdoorCount) Frontdoor · \(workerCount) Worker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    SourceBadge(label: "ACP", count: model.realtimeACPCount, color: .blue)
                    SourceBadge(label: "LOCAL", count: model.realtimeLocalCount, color: .purple)
                }
                if (projection?.activeTurnCount ?? realtimeSessions.filter(\.isActive).count) > 0 {
                    Label("\(projection?.activeTurnCount ?? realtimeSessions.filter(\.isActive).count)개 진행 중", systemImage: "waveform")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Picker("보기 방식", selection: $settings.monitorViewMode) {
                    Label("Branch", systemImage: "point.3.connected.trianglepath.dotted").tag("branch")
                    Label("Map", systemImage: "circle.grid.cross").tag("map")
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            .padding(12)
            Divider()
            if isMap {
                AgentMapView(sessions: realtimeSessions, inbox: model.realtimeInbox)
            } else if let projection {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        BranchCanvas(projection: projection)
                            .frame(
                                width: max(projection.width, geometry.size.width - 28),
                                height: max(geometry.size.height - 28, 680)
                            )
                            .padding(14)
                    }
                }
            }
        }
        .task { model.startIfNeeded() }
    }

    private var liveStatusText: String {
        switch model.phase {
        case .connected: "LIVE"
        case .starting: "연결 중"
        case .degraded: "재연결 중"
        case .idle: "대기"
        case .disconnected: "연결 끊김"
        }
    }

    private var liveStatusColor: Color {
        switch model.phase {
        case .connected: .green
        case .starting, .degraded: .orange
        case .idle: .secondary
        case .disconnected: .red
        }
    }
}

private struct HoveredTurn {
    let lane: GraphLane
    let turn: GraphTurnPoint
}

private struct BranchCanvas: View {
    let projection: GraphProjection
    @State private var hoveredTurnId: String?

    var body: some View {
        GeometryReader { geometry in
            let top = 76.0
            let bottom = 34.0
            let plotHeight = max(geometry.size.height - top - bottom, 1)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for index in 0...5 {
                        let y = top + plotHeight * Double(index) / 5
                        var line = Path()
                        line.move(to: CGPoint(x: 42, y: y))
                        line.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(line, with: .color(.secondary.opacity(0.14)), lineWidth: 1)
                    }

                    for group in projection.groups {
                        var trunk = Path()
                        trunk.move(to: CGPoint(x: group.trunkX, y: top))
                        trunk.addLine(to: CGPoint(x: group.trunkX, y: top + plotHeight))
                        context.stroke(trunk, with: .color(.secondary.opacity(0.68)), lineWidth: 3)
                        context.draw(
                            Text(group.opener.uppercased()).font(.caption2.bold()).foregroundColor(.primary),
                            at: CGPoint(x: group.trunkX, y: 17), anchor: .top
                        )
                        let folder = URL(fileURLWithPath: group.cwd).lastPathComponent
                        context.draw(
                            Text(folder.isEmpty ? group.cwd : folder).font(.caption2).foregroundColor(.secondary),
                            at: CGPoint(x: group.trunkX, y: 38), anchor: .top
                        )
                    }

                    for lane in projection.lanes {
                        draw(lane: lane, context: &context, top: top, plotHeight: plotHeight)
                    }
                }

                ForEach(projection.lanes) { lane in
                    ForEach(lane.turns) { turn in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .frame(width: 198, height: 44)
                            .position(x: lane.laneX + 92, y: top + turn.progress * plotHeight)
                            .onHover { isInside in
                                if isInside {
                                    hoveredTurnId = turn.id
                                } else if hoveredTurnId == turn.id {
                                    hoveredTurnId = nil
                                }
                            }
                            .accessibilityLabel(
                                "Prompt: \(String(turn.prompt.prefix(240))). Return: \(String(turn.response.prefix(240)))"
                            )
                    }
                }

                if let item = hoveredItem {
                    TurnHoverCard(lane: item.lane, turn: item.turn)
                        .frame(width: 390)
                        .position(
                            x: cardX(for: item.lane.laneX, canvasWidth: geometry.size.width),
                            y: cardY(for: top + item.turn.progress * plotHeight, canvasHeight: geometry.size.height)
                        )
                        .allowsHitTesting(false)
                        .zIndex(20)
                }

                if projection.turnCount == 0 {
                    ContentUnavailableView(
                        "현재 진행 중인 ACP Worker가 없습니다",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Frontdoor 세션에서 Worker prompt가 시작되면 해당 Frontdoor 아래에 실시간으로 표시됩니다.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomLeading) {
            Label("ACP + Local · Hover: Prompt/Return/이벤트", systemImage: "cursorarrow.motionlines")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ACP와 로컬 Agent 실시간 대화 흐름")
    }

    private var hoveredItem: HoveredTurn? {
        guard let hoveredTurnId else { return nil }
        for lane in projection.lanes {
            if let turn = lane.turns.first(where: { $0.id == hoveredTurnId }) {
                return HoveredTurn(lane: lane, turn: turn)
            }
        }
        return nil
    }

    private func draw(lane: GraphLane, context: inout GraphicsContext, top: Double, plotHeight: Double) {
        let color = providerColor(lane.session.provider)
        context.draw(
            Text("[\(lane.session.sourceLabel)] \(lane.session.provider) · \(lane.session.model ?? "default")")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color),
            at: CGPoint(x: lane.laneX, y: 18), anchor: .top
        )
        guard let first = lane.turns.first else { return }
        let firstY = top + first.progress * plotHeight
        let lastY = lane.session.isActive
            ? top + plotHeight
            : top + (lane.turns.last?.progress ?? first.progress) * plotHeight

        var branch = Path()
        branch.move(to: CGPoint(x: lane.trunkX, y: firstY))
        branch.addCurve(
            to: CGPoint(x: lane.laneX, y: min(firstY + 14, lastY)),
            control1: CGPoint(x: lane.laneX, y: firstY),
            control2: CGPoint(x: lane.laneX, y: firstY)
        )
        branch.addLine(to: CGPoint(x: lane.laneX, y: lastY))
        context.stroke(branch, with: .color(color), lineWidth: 2.4)

        if !lane.session.isActive, lane.turns.last?.completed == true {
            var merge = Path()
            merge.move(to: CGPoint(x: lane.laneX, y: lastY))
            merge.addCurve(
                to: CGPoint(x: lane.trunkX, y: lastY),
                control1: CGPoint(x: lane.laneX, y: lastY),
                control2: CGPoint(x: lane.laneX, y: lastY)
            )
            context.stroke(merge, with: .color(color), lineWidth: 2.4)
        }

        for turn in lane.turns {
            let y = top + turn.progress * plotHeight
            let nodeColor: Color = turn.failed ? .red : (turn.completed ? .green : .orange)
            let outer = CGRect(x: lane.laneX - 7, y: y - 7, width: 14, height: 14)
            let inner = CGRect(x: lane.laneX - 3, y: y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: outer), with: .color(nodeColor))
            context.fill(Path(ellipseIn: inner), with: .color(.white))
        }
    }

    private func cardX(for nodeX: Double, canvasWidth: Double) -> Double {
        let preferred = nodeX + 220
        return min(max(preferred, 205), max(canvasWidth - 205, 205))
    }

    private func cardY(for nodeY: Double, canvasHeight: Double) -> Double {
        min(max(nodeY, 155), max(canvasHeight - 155, 155))
    }
}

private struct SourceBadge: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        Text("\(label) \(count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct TurnHoverCard: View {
    let lane: GraphLane
    let turn: GraphTurnPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("보낸 Prompt", systemImage: "arrow.up.message.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(lane.session.provider) · \(lane.session.model ?? "default")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(String(turn.prompt.prefix(1_200)))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Label("받은 Return", systemImage: "arrow.down.message.fill")
                .font(.caption.bold())
                .foregroundStyle(turn.failed ? .red : .green)
            Text(returnText)
                .font(.callout)
                .foregroundStyle(turn.response.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(10)
            Divider()
            Label("최근 이벤트", systemImage: "list.bullet.rectangle")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(Array(turn.events.suffix(5))) { event in
                HStack(spacing: 7) {
                    Image(systemName: eventSymbol(event.type))
                        .foregroundStyle(eventColor(event.type))
                        .frame(width: 14)
                    Text(event.type.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2.weight(.medium))
                    Text(String(event.summary.prefix(100)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.28)))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }

    private var returnText: String {
        if !turn.response.isEmpty { return String(turn.response.suffix(2_000)) }
        return turn.completed ? "(텍스트 return 없음)" : "응답 생성 중…"
    }
}
