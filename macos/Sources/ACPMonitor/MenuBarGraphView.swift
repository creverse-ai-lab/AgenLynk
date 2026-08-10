import SwiftUI

/// Compact, left-to-right variant of the Monitoring branch graph, sized for the
/// menu-bar popover.
///
/// The Monitoring window runs time down the Y axis and gives every session a
/// 210pt wide lane. A popover has the opposite budget — plenty of width, very
/// little height — so this view transposes the same `GraphProjection`: time
/// runs left to right, each session is one thin lane, and the label column is
/// pinned outside the horizontal scroll so lane identity survives scrolling.
struct MenuBarLiveGraph: View {
    let projection: GraphProjection
    /// Visible width of the scrolling timeline. Fixed by the caller instead of
    /// measured, so the popover frame can never change size.
    let timelineWidth: Double

    private let labelWidth: Double = 132
    private let laneHeight: Double = 30
    private let turnSpacing: Double = 44
    private let leadInset: Double = 14
    private let trailInset: Double = 18
    /// Room reserved after the newest node for that lane's model tag.
    private let modelTagWidth: Double = 92

    var body: some View {
        let lanes = projection.lanesOrderedByTrunk
        HStack(spacing: 0) {
            labelColumn(lanes)
                .frame(width: labelWidth, alignment: .leading)
            Divider()
            ScrollView(.horizontal, showsIndicators: true) {
                timeline(lanes)
                    .frame(width: canvasWidth, height: Double(lanes.count) * laneHeight)
            }
            .frame(width: timelineWidth)
        }
        .frame(height: Double(lanes.count) * laneHeight, alignment: .top)
    }

    /// Wide enough that every turn keeps its own slot, plus room for the model
    /// tag past the newest node; the caller's fixed viewport scrolls across it.
    private var canvasWidth: Double {
        max(
            timelineWidth,
            Double(projection.turnCount) * turnSpacing + leadInset + trailInset + modelTagWidth
        )
    }

    /// Left column: which project this lane is working in. The model belongs on
    /// the right, next to the newest turn, so scanning down this column answers
    /// "what is being worked on where" without reading the timeline.
    private func labelColumn(_ lanes: [GraphLane]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lanes) { lane in
                let isFrontdoor = lane.session.isFrontdoorRecord
                HStack(spacing: 3) {
                    if !isFrontdoor {
                        Text("└").font(.caption2).foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(projectName(lane))
                            .font(.caption2.weight(isFrontdoor ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text(projectDetail(lane))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: laneHeight)
                .help(laneTooltip(lane))
            }
        }
    }

    private func group(for lane: GraphLane) -> GraphGroup? {
        projection.groups.first { $0.trunkX == lane.trunkX }
    }

    private func projectName(_ lane: GraphLane) -> String {
        let cwd = lane.session.cwd
        guard !cwd.isEmpty else { return lane.session.opener ?? lane.session.provider }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Frontdoor rows show where the project lives; worker rows show their own
    /// folder only when it differs from the Frontdoor's, otherwise the opener
    /// that started them.
    private func projectDetail(_ lane: GraphLane) -> String {
        let cwd = lane.session.cwd
        if lane.session.isFrontdoorRecord {
            guard !cwd.isEmpty else { return "Frontdoor" }
            let parent = URL(fileURLWithPath: cwd).deletingLastPathComponent().path
            return abbreviateHome(parent)
        }
        if let groupCwd = group(for: lane)?.cwd, !cwd.isEmpty, cwd != groupCwd {
            return abbreviateHome(cwd)
        }
        return (lane.session.opener ?? "worker").capitalized + " Worker"
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func timeline(_ lanes: [GraphLane]) -> some View {
        Canvas { context, size in
            for (index, lane) in lanes.enumerated() {
                let y = laneHeight * (Double(index) + 0.5)
                let isFrontdoor = lane.session.isFrontdoorRecord

                var rail = Path()
                rail.move(to: CGPoint(x: leadInset, y: y))
                rail.addLine(to: CGPoint(x: size.width - trailInset, y: y))
                context.stroke(
                    rail,
                    with: .color(.secondary.opacity(isFrontdoor ? 0.34 : 0.18)),
                    style: StrokeStyle(lineWidth: isFrontdoor ? 2 : 1, dash: lane.turns.isEmpty ? [3, 4] : [])
                )

                let points = lane.turns.map { turn in
                    (turn: turn, x: x(for: turn.progress, canvasWidth: size.width))
                }
                // A solid span between the first and last turn reads as "this
                // lane was busy across this stretch of time".
                if let first = points.first, let last = points.last, points.count > 1 {
                    var span = Path()
                    span.move(to: CGPoint(x: first.x, y: y))
                    span.addLine(to: CGPoint(x: last.x, y: y))
                    context.stroke(span, with: .color(.blue.opacity(0.55)), lineWidth: 2)
                }

                for point in points {
                    let radius: Double = point.turn.completed ? 4 : 5.5
                    let rect = CGRect(
                        x: point.x - radius, y: y - radius,
                        width: radius * 2, height: radius * 2
                    )
                    if point.turn.failed {
                        context.fill(Path(ellipseIn: rect), with: .color(.red))
                    } else if point.turn.completed {
                        context.fill(Path(ellipseIn: rect), with: .color(.blue))
                    } else {
                        // In-flight turn: a ring, so it reads differently from
                        // the finished dots without needing animation.
                        context.stroke(Path(ellipseIn: rect), with: .color(.green), lineWidth: 2)
                        let core = rect.insetBy(dx: 2.6, dy: 2.6)
                        context.fill(Path(ellipseIn: core), with: .color(.green))
                    }
                }

                // The model runs at the newest end of the lane, so it is
                // labelled there rather than in the project column.
                let tagX = (points.last?.x ?? leadInset) + 12
                let inFlight = points.last.map { !$0.turn.completed } ?? false
                context.draw(
                    Text(modelLabel(lane))
                        .font(.system(size: 9, weight: inFlight ? .semibold : .regular))
                        .foregroundColor(inFlight ? .green : .secondary),
                    at: CGPoint(x: tagX, y: y),
                    anchor: .leading
                )
            }
        }
        .overlay(alignment: .topLeading) { tooltipTargets(lanes) }
    }

    /// Transparent hit targets so hovering a node reveals its prompt. Canvas
    /// itself cannot carry per-shape help text.
    private func tooltipTargets(_ lanes: [GraphLane]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                ForEach(lane.turns) { turn in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .frame(width: turnSpacing, height: laneHeight)
                        .offset(
                            x: x(for: turn.progress, canvasWidth: canvasWidth) - turnSpacing / 2,
                            y: laneHeight * Double(index)
                        )
                        .help(turnTooltip(lane: lane, turn: turn))
                }
            }
        }
        .allowsHitTesting(true)
    }

    private func x(for progress: Double, canvasWidth: Double) -> Double {
        leadInset + progress * (canvasWidth - leadInset - trailInset)
    }

    /// Abbreviated so a long model id cannot push the tag past its reserved
    /// width. The full value stays in the lane tooltip.
    private func modelLabel(_ lane: GraphLane) -> String {
        let model = (lane.session.model ?? "").trimmingCharacters(in: .whitespaces)
        let value = model.isEmpty ? lane.session.provider : model
        return value.count > 18 ? String(value.prefix(17)) + "…" : value
    }

    private func laneTooltip(_ lane: GraphLane) -> String {
        let role = lane.session.isFrontdoorRecord ? "Frontdoor" : "Worker"
        let cwd = lane.session.cwd.isEmpty ? lane.session.sessionId : lane.session.cwd
        return "\(role) · \(lane.session.provider) · \(lane.session.model ?? "default")\n\(cwd)"
    }

    private func turnTooltip(lane: GraphLane, turn: GraphTurnPoint) -> String {
        let status = turn.failed ? "실패" : (turn.completed ? "완료" : "진행 중")
        let prompt = turn.promptPreview.isEmpty ? "(prompt 없음)" : turn.promptPreview
        return "\(status) · \(lane.session.provider)\n\(prompt)"
    }
}
