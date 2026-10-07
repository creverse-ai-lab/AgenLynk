import LynkArt
import SwiftUI

// The notch's home page: the same Frontdoor cards as the menu bar, each with
// a status icon that says what it is doing, and the notch chat as one more
// card behind a "+".

/// How a session's state reads at a glance: icon, color and a short label.
/// Running splits into "thinking" and "working on a step" when the current
/// step is known, the way the person tells them apart.
struct NotchStatusStyle: Equatable {
    let icon: String
    let color: Color
    let label: String
    let animated: Bool

    init(urgency: MenuBarPipeline.Urgency, currentStep: String? = nil) {
        switch urgency {
        case .permission: (icon, color, label, animated) = ("lock.shield.fill", .orange, "권한 대기", true)
        case .input: (icon, color, label, animated) = ("questionmark.bubble.fill", .orange, "입력 대기", true)
        case .error: (icon, color, label, animated) = ("xmark.octagon.fill", .red, "오류", false)
        case .running:
            if currentStep?.isEmpty == false {
                (icon, color, label, animated) = ("hammer.fill", .blue, "작업 중", true)
            } else {
                (icon, color, label, animated) = ("sparkles", .purple, "생각 중", true)
            }
        case .idle: (icon, color, label, animated) = ("zzz", .indigo, "쉬는 중", false)
        case .closed: (icon, color, label, animated) = ("power.circle.fill", .gray, "종료됨", false)
        }
    }

    /// A Frontdoor whose turn ended and whose CLI holds it open for a notch
    /// reply: neither working nor done.
    static let awaitingReply = NotchStatusStyle(icon: "arrowshape.turn.up.left.fill", color: .teal, label: "답장 대기", animated: true)

    private init(icon: String, color: Color, label: String, animated: Bool) {
        (self.icon, self.color, self.label, self.animated) = (icon, color, label, animated)
    }

    init(status: String?) {
        self.init(urgency: MenuBarPipeline.Urgency(status: status ?? "idle"))
    }
}

struct NotchStatusBadge: View {
    let style: NotchStatusStyle
    var showsLabel = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
                .symbolEffect(.pulse, isActive: style.animated)
            if showsLabel {
                Text(style.label).font(.caption2.weight(.semibold)).foregroundStyle(style.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(style.label)
    }
}

extension MenuBarPipeline {
    /// The notch's view of the pipeline: every Worker belongs to a Frontdoor,
    /// so ones the monitor could not place are left to the dashboard, and so
    /// are the idle Workers of a Frontdoor that has ended (no Frontdoor to
    /// show them under). Cards, the pill and the counts all read this one list.
    var notchCards: MenuBarPipeline {
        MenuBarPipeline(
            activeCards: activeCards.filter { !$0.frontdoor.isUnattributed },
            idleCards: idleCards.filter { !$0.frontdoor.isUnattributed && !$0.frontdoor.frontdoorEnded }
        )
    }
}

struct NotchSessionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: NotchChatController
    @ObservedObject var store: NotchChatStore

    var body: some View {
        VStack(spacing: 10) {
            header
            if let alert = controller.alert {
                NotchAlertRow(alert: alert, controller: controller)
                    .id(alert.id)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.sessionId != nil { chatCard }
                    let pipeline = model.menuBarPipeline.notchCards
                    let replying = controller.replyingSessionIds
                    // A Frontdoor holding its turn open for a reply is not resting:
                    // it is listed with the active ones.
                    let awaiting = { (card: MenuBarPipeline.Card) in
                        FrontdoorPhase.members(card.frontdoor).contains { replying.contains($0.sessionId) }
                    }
                    let active = pipeline.activeCards + pipeline.idleCards.filter(awaiting)
                    let idle = pipeline.idleCards.filter { !awaiting($0) }
                    ForEach(active) { card in NotchSessionCard(card: card, replying: replying) }
                    if !idle.isEmpty {
                        Text("쉬는 중")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        ForEach(idle) { card in NotchSessionCard(card: card, replying: replying) }
                    }
                    if active.isEmpty && idle.isEmpty && store.sessionId == nil {
                        Text("지금 보이는 Frontdoor가 없어요.\n+ 를 눌러 채팅을 시작할 수 있어요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AgenLynk").font(.headline)
            let counts = MenuBarCounts(model.menuBarPipeline.notchCards)
            if counts.main > 0 || counts.sub > 0 {
                Text("Frontdoor \(counts.main) / Worker \(counts.sub)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.openChat(new: true) } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                .buttonStyle(.borderless)
                .help("새 채팅")
            Menu {
                Button("표시 요소 설정…") { NotchChatController.openSettings() }
                Toggle("끝난 Frontdoor에 노치에서 답장", isOn: Binding(
                    get: { controller.repliesEnabled },
                    set: { controller.setRepliesEnabled($0) }
                ))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { controller.collapse(restoreFocus: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
        }
    }

    /// The notch chat, as one card among the sessions.
    private var chatCard: some View {
        Button { controller.openChat(new: false) } label: {
            HStack(spacing: 10) {
                ProviderOrb(provider: store.sessionProvider ?? store.provider, size: 44, mood: AgentMascot.Mood(urgency: chatUrgency))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("채팅 · \(providerDisplayLabel(store.sessionProvider ?? store.provider))")
                            .font(.callout.weight(.semibold))
                        NotchStatusBadge(style: NotchStatusStyle(urgency: chatUrgency, currentStep: store.activity))
                    }
                    Text(store.activity ?? store.owner.map { "↳ \($0.displayName) 소속 Worker" } ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var chatUrgency: MenuBarPipeline.Urgency {
        if store.permission != nil { return .permission }
        return MenuBarPipeline.Urgency(status: store.status ?? "idle")
    }
}

/// One Frontdoor: who, what state it is in, what it is doing, how many
/// Workers it has out. A tap opens the session that needs attention.
private struct NotchSessionCard: View {
    let card: MenuBarPipeline.Card
    let replying: Set<String>

    var body: some View {
        let focus = card.focus
        let awaitingReply = FrontdoorPhase.members(card.frontdoor).contains { replying.contains($0.sessionId) }
        let style = awaitingReply ? .awaitingReply : NotchStatusStyle(urgency: card.urgency, currentStep: focus?.currentStep)
        let detailId = focus?.session.sessionId ?? card.frontdoor.root?.sessionId
        let root = card.frontdoor.root
        Button {
            // The window it runs in when that is known; its details otherwise.
            if let root, SessionWindowJumper.canJump(root) {
                SessionWindowJumper.jump(to: root)
            } else if let detailId {
                NotificationCenter.default.post(name: .openSessionDetail, object: detailId)
            }
        } label: {
            HStack(spacing: 10) {
                ProviderOrb(provider: card.frontdoor.provider, size: 44, mood: awaitingReply ? .waiting : AgentMascot.Mood(urgency: card.urgency))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(card.frontdoor.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                        NotchStatusBadge(style: style)
                    }
                    if let line = focus?.waitReason ?? focus?.currentStep {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                let workers = card.frontdoor.workers.filter(\.isActive).count
                if workers > 0 {
                    Label("\(workers)", systemImage: "person.2.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("실행 중인 Worker \(workers)개")
                }
                if SessionWindowJumper.canJump(root) {
                    Image(systemName: "macwindow.on.rectangle").foregroundStyle(.tertiary).help("눌러서 이 세션의 창으로 이동")
                }
                Button {
                    if let detailId { NotificationCenter.default.post(name: .openSessionDetail, object: detailId) }
                } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help("세션 상세")
            }
            .padding(10)
            .background(Color.white.opacity(card.urgency.needsUser ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if card.urgency.needsUser {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(style.color.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
