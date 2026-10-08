import ACPShared
import SwiftUI

extension MenuBarPipeline.Stage {
    /// The step's status color (docs/ux-policy.md §3), shared by the menu bar
    /// and the dashboard cards.
    var color: Color {
        // Winding down, not working: gray like the dashboard.
        if session.status == "cancelling" { return .secondary }
        switch urgency {
        case .permission, .input: return .orange
        case .error: return .red
        case .running: return .green
        case .idle, .closed: return .secondary
        }
    }
}

/// The dashboard's 현황 view: one card per Frontdoor, the menu bar's
/// pipelines with room to spare. Moving steps are listed; Workers that only
/// rest (idle, closed) fold into a bordered "대기 중 Worker N개" box per card. The selected
/// Frontdoor's card is outlined and scrolled into view — cards never reorder
/// on a click, so the one just clicked stays under the pointer.
struct DashboardCardsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cards: [MenuBarPipeline.Card]
    let selectedFrontdoorId: String?
    let selectedSessionId: String?
    var emptyState = SequenceEmptyState()
    let selectFrontdoor: (String) -> Void
    let selectStage: (_ frontdoorId: String, _ sessionId: String) -> Void
    @State private var expandedResting: Set<String> = []
    @State private var renamingSession: GatewaySession?
    /// The card clicked last: its own click selects it but must not scroll.
    @State private var clickedCardId: String?

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)]

    var body: some View {
        if cards.isEmpty {
            ContentUnavailableView {
                Label(emptyState.title, systemImage: emptyState.symbol)
            } description: {
                Text(emptyState.description)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(cards) { card in
                            DashboardCardView(
                                card: card,
                                selected: card.id == selectedFrontdoorId,
                                selectedSessionId: selectedSessionId,
                                showResting: expandedBinding(card.id),
                                selectFrontdoor: {
                                    if card.id != selectedFrontdoorId { clickedCardId = card.id }
                                    selectFrontdoor(card.id)
                                },
                                selectStage: {
                                    if card.id != selectedFrontdoorId { clickedCardId = card.id }
                                    selectStage(card.id, $0)
                                },
                                rename: { renamingSession = $0 }
                            )
                            .id(card.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear { scrollToSelection(proxy, animated: false) }
                .onChange(of: selectedFrontdoorId) { _, next in
                    // Selected elsewhere (the sidebar, the menu bar): bring
                    // its card into view. Clicked here: it is already there.
                    defer { clickedCardId = nil }
                    guard next != clickedCardId else { return }
                    scrollToSelection(proxy, animated: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("작업 현황. Frontdoor마다 카드 한 장")
            .sheet(item: $renamingSession) { session in
                SessionRenameSheet(session: session)
            }
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedResting.contains(id) },
            set: { open in
                if open { expandedResting.insert(id) } else { expandedResting.remove(id) }
            }
        )
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = selectedFrontdoorId, cards.contains(where: { $0.id == id }) else { return }
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
        } else {
            proxy.scrollTo(id)
        }
    }
}

/// One Frontdoor's card: header, moving steps, folded resting Workers.
private struct DashboardCardView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    let card: MenuBarPipeline.Card
    let selected: Bool
    let selectedSessionId: String?
    @Binding var showResting: Bool
    let selectFrontdoor: () -> Void
    let selectStage: (String) -> Void
    let rename: (GatewaySession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(card.stages) { stage in stageButton(stage) }
                if !card.restingStages.isEmpty { restingSection }
            }
        }
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : border, lineWidth: selected ? 2 : 1)
        )
    }

    private var name: String { settings.frontdoorName(id: card.frontdoor.id, auto: card.frontdoor.displayName) }

    private var header: some View {
        HStack(spacing: 6) {
            headerButton
            JumpToWindowButton(session: card.frontdoor.root)
        }
    }

    private var headerButton: some View {
        Button(action: selectFrontdoor) {
            HStack(spacing: 6) {
                ProviderIcon(provider: card.frontdoor.provider, size: 18)
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(card.frontdoor.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(card.frontdoor.statusKey))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 6)
                if let total = card.work.totalTokens {
                    Text("작업 \(formatTokenCount(total))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help("이 작업(Frontdoor와 Worker들)의 세션 누적 토큰 합계입니다. 입력은 cache 포함.")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("클릭해 이 Frontdoor 선택")
        .accessibilityLabel("\(name), \(card.frontdoor.statusText)")
    }

    private func stageButton(_ stage: MenuBarPipeline.Stage) -> some View {
        Button { selectStage(stage.id) } label: {
            DashboardStageRow(
                stage: stage,
                selected: stage.id == selectedSessionId,
                isFocus: stage.id == card.focus?.id && stage.urgency <= .running
            )
        }
        .buttonStyle(.plain)
        .help("클릭해 이 세션 선택 · 우클릭으로 이름 바꾸기")
        .contextMenu {
            Button("세션 상세 열기") { openWindow(id: "session-detail", value: stage.id) }
            Button("이름 바꾸기…") { rename(stage.session) }
        }
    }

    /// Resting Workers in their own folded, bordered box at the card's foot.
    private var restingSection: some View {
        let count = card.restingStages.count
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                showResting.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showResting ? "chevron.down" : "chevron.right")
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
            .help(showResting ? "대기 중 Worker 접기" : "대기 중 Worker \(count)개 펼치기")
            .accessibilityLabel(showResting ? "대기 중 Worker 접기" : "대기 중 Worker \(count)개 펼치기")
            if showResting {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(card.restingStages) { stage in restingButton(stage, now: context.date) }
                    }
                }
            }
        }
        .padding(6)
        .restingBox()
        .padding(.top, 4)
    }

    private func restingButton(_ stage: MenuBarPipeline.Stage, now: Date) -> some View {
        Button { selectStage(stage.id) } label: {
            RestingStageRow(stage: stage, selected: stage.id == selectedSessionId, now: now)
        }
        .buttonStyle(.plain)
        .help("\(sessionRoleLabel(stage.session, depth: stage.depth)) · 클릭해 이 세션 선택 · 우클릭으로 이름 바꾸기")
        .contextMenu {
            Button("세션 상세 열기") { openWindow(id: "session-detail", value: stage.id) }
            Button("이름 바꾸기…") { rename(stage.session) }
        }
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.06) }
        return card.urgency.needsUser ? Color.orange.opacity(0.08) : Color(nsColor: .textBackgroundColor)
    }

    private var border: Color {
        card.urgency.needsUser ? Color.orange.opacity(0.45) : Color(nsColor: .separatorColor)
    }
}

/// One step: indent by depth, status dot, provider, name, role, status with
/// elapsed time, then what it waits for or is doing, and its tokens.
private struct DashboardStageRow: View {
    @EnvironmentObject private var settings: AppSettings
    let stage: MenuBarPipeline.Stage
    let selected: Bool
    var isFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(stage.color).frame(width: 7, height: 7)
                ProviderIcon(provider: stage.session.provider, size: 14)
                Text(settings.stepName(stage.session))
                    .font(.caption.weight(stage.depth == 0 ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(role)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                if stage.session.cannotObservePermission && stage.urgency <= .running {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("권한 대기 감지 불가 (hook 꺼짐) · 설정 > 모니터링에서 켤 수 있습니다")
                        .accessibilityLabel("권한 대기 감지 불가 (hook 꺼짐)")
                }
                Spacer(minLength: 4)
                if isFocus {
                    Text("← 현재").font(.caption2.weight(.semibold)).foregroundStyle(stage.color).fixedSize()
                }
                StageStatusText(label: sessionStatusLabel(stage.session.status), startedAt: stage.turnStartedAt, color: stage.color)
            }
            if detail != nil || tokens != nil {
                HStack(spacing: 6) {
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(stage.waitReason != nil ? Color.orange : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    if let tokens {
                        Text(tokens.text)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .help(tokens.help)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .padding(.leading, CGFloat(min(stage.depth, 6)) * 14)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var role: String { sessionRoleLabel(stage.session, depth: stage.depth) }

    /// The wait reason while it needs the user, else the running turn's step.
    private var detail: String? { stage.waitReason ?? stage.currentStep }

    /// This turn's tokens while one runs, else the session's total.
    private var tokens: (text: String, help: String)? {
        if stage.forecast.currentTurnRunning {
            if let current = stage.forecast.currentTurnTokens {
                return ("이번 턴 \(formatTokenCount(current))", "지금 실행 중인 턴이 지금까지 쓴 토큰입니다.")
            }
            return ("이번 턴 집계 중", "이 CLI는 턴이 끝날 때 토큰을 확정합니다.")
        }
        guard let total = stage.session.usage?.total else { return nil }
        return (formatTokenCount(total), "세션 누적 토큰(입력은 cache 포함)")
    }
}

/// A resting Worker in the card's box, one compact line: provider, name,
/// status, how long ago it last moved.
private struct RestingStageRow: View {
    @EnvironmentObject private var settings: AppSettings
    let stage: MenuBarPipeline.Stage
    let selected: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 5) {
            ProviderIcon(provider: stage.session.provider, size: 12)
            Text(settings.stepName(stage.session))
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(sessionStatusLabel(stage.session.status))
                .font(.caption2.weight(.medium))
                .foregroundStyle(stage.color)
                .fixedSize()
            if let updated = stage.session.updatedAt.flatMap(parseTimestamp) {
                Text(relativeTimeText(from: updated, to: now))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .padding(.leading, 16)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// "실행 중 · 4분째": the only part of a card that changes with the clock, so
/// it alone ticks.
private struct StageStatusText: View {
    let label: String
    let startedAt: Date?
    let color: Color

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                text("\(label) · \(elapsedText(from: startedAt, to: context.date))")
            }
        } else {
            text(label)
        }
    }

    private func text(_ value: String) -> some View {
        Text(value)
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}
