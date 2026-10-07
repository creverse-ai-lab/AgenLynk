import AppKit
import Combine
import LynkArt
import SwiftUI

// Notch chat: a small panel that hangs from the notch (or the top of a screen
// without one) and chats with a Worker through the Gateway. The Worker runs on
// its CLI's own login, so a chat uses the subscription, not an API key.

struct NotchChatMessage: Identifiable, Equatable {
    enum Role { case user, agent, note }
    let id = UUID()
    let role: Role
    var text: String
}

struct NotchChatPermission: Equatable {
    struct Option: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: String
    }
    let requestId: Int
    let title: String
    let options: [Option]
}

@MainActor
final class NotchChatStore: ObservableObject {
    static let providers = ["claude", "codex", "grok"]
    private static let activeStatuses: Set<String> = ["running", "waiting_permission", "waiting_input", "cancelling", "restoring"]

    @Published var provider = "claude"
    /// A folder the person picked; otherwise the Worker works where its
    /// Frontdoor does.
    @Published var customCwd: String?
    var cwd: String {
        if let customCwd { return customCwd }
        if let folder = owner?.root?.cwd, !folder.isEmpty { return folder }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
    @Published private(set) var sessionId: String?
    @Published private(set) var sessionProvider: String?
    /// The chat so far, its oldest lines dropped past a cap: a long-lived
    /// chat used to keep every streamed message for the app's lifetime.
    @Published private(set) var messages: [NotchChatMessage] = [] {
        didSet {
            if messages.count > Self.messageLimit { messages.removeFirst(messages.count - Self.messageLimit) }
        }
    }
    private static let messageLimit = 300
    @Published private(set) var status: String?
    @Published private(set) var permission: NotchChatPermission?
    @Published private(set) var busy = false
    /// The running turn's latest tool call, for the one-line ticker.
    @Published private(set) var activity: String?
    @Published var draft = ""
    /// The Frontdoor this chat's Worker is opened for (its root's monitor
    /// id). ACP Gateway keeps every Worker under a top-level Frontdoor, so
    /// the notch never opens one of its own.
    @Published var ownerId: String?

    private weak var model: AppModel?
    private var cursor = 0
    private var pollTask: Task<Void, Never>?
    /// Bumped by new chat / attach so a request in flight for the previous
    /// chat cannot write into this one.
    private var generation = 0

    init(model: AppModel) {
        self.model = model
    }

    var isRunning: Bool { status.map(Self.activeStatuses.contains) ?? false }

    /// Gateway sessions the chat can join: not local CLI records, not closed.
    var attachableSessions: [GatewaySession] {
        (model?.sessions ?? []).filter { !$0.isLocalSource && $0.status != "closed" }
    }

    /// Frontdoors a chat can be opened for: live local roots of a CLI the
    /// Gateway can run, most recently active first.
    var owners: [FrontdoorSession] {
        (model?.frontdoorSessions ?? [])
            .filter { frontdoor in
                guard let root = frontdoor.root, root.isLocalSource, root.status != "closed" else { return false }
                return Self.providers.contains(root.provider)
            }
    }

    var owner: FrontdoorSession? {
        let owners = owners
        return owners.first { $0.root?.sessionId == ownerId } ?? owners.first
    }

    func newChat() {
        generation += 1
        ownerId = nil
        customCwd = nil
        // The previous chat's request no longer holds this one's send button.
        busy = false
        activity = nil
        pollTask?.cancel()
        sessionId = nil
        sessionProvider = nil
        status = nil
        permission = nil
        cursor = 0
        messages = []
    }

    /// Joins an existing Gateway session; the next message goes to it.
    func attach(_ session: GatewaySession) {
        newChat()
        sessionId = session.sessionId
        sessionProvider = session.provider
        provider = session.provider
        messages = [NotchChatMessage(role: .note, text: "\(session.displayName) 세션에 연결했습니다.")]
        // A turn already running streams into a bubble of its own.
        if session.isActive {
            status = session.status
            messages.append(NotchChatMessage(role: .agent, text: ""))
        }
        startPolling()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, !isRunning else { return }
        // A Frontdoor picked and then gone is not silently swapped for another.
        if sessionId == nil, let ownerId, !owners.contains(where: { $0.root?.sessionId == ownerId }) {
            messages.append(NotchChatMessage(role: .note, text: "고른 Frontdoor가 끝났어요. 다른 Frontdoor를 골라 주세요."))
            self.ownerId = nil
            return
        }
        // Read together, now: the Frontdoor list can change while the
        // request is on its way.
        let ownerRoot = sessionId == nil ? owner?.root?.sessionId : nil
        let openCwd = cwd
        let openProvider = provider
        if sessionId == nil, ownerRoot == nil {
            messages.append(NotchChatMessage(role: .note, text: "채팅을 맡길 Frontdoor가 없어요. 터미널에서 Claude·Codex·Grok을 먼저 실행해 주세요."))
            return
        }
        draft = ""
        messages.append(NotchChatMessage(role: .user, text: text))
        busy = true
        let started = generation
        // The session this message is for, fixed now: the chat may be
        // switched while the connection is awaited.
        let target = sessionId
        Task {
            defer { if started == generation { busy = false } }
            do {
                guard let (client, endpoint) = await model?.chatConnection() else {
                    throw NotchChatError("Gateway monitor에 아직 연결되지 않았습니다.")
                }
                guard started == generation else { return }
                if target == nil {
                    let opened = try await client.chatPost(endpoint: endpoint, path: "open", body: [
                        "frontdoor": .string(ownerRoot ?? ""),
                        "provider": .string(openProvider),
                        "cwd": .string(openCwd),
                        "permissionPolicy": .string("ask")
                    ])
                    guard let id = opened.objectValue?["sessionId"]?.stringValue else {
                        throw NotchChatError("세션을 열지 못했습니다.")
                    }
                    guard started == generation else {
                        // The chat was left while this opened: close the
                        // Worker rather than leave it behind unseen.
                        _ = try? await client.chatPost(endpoint: endpoint, path: "close", body: ["sessionId": .string(id)])
                        return
                    }
                    ownerId = ownerRoot
                    sessionId = id
                    sessionProvider = openProvider
                }
                guard let sessionId = target ?? sessionId else { return }
                _ = try await client.chatPost(endpoint: endpoint, path: "prompt", body: [
                    "sessionId": .string(sessionId),
                    "text": .string(text)
                ])
                guard started == generation else { return }
                status = "running"
                messages.append(NotchChatMessage(role: .agent, text: ""))
                startPolling()
            } catch {
                guard started == generation else { return }
                messages.append(NotchChatMessage(role: .note, text: error.localizedDescription))
            }
        }
    }

    func answer(_ option: NotchChatPermission.Option) {
        guard let sessionId, let permission else { return }
        self.permission = nil
        Task {
            do {
                guard let (client, endpoint) = await model?.chatConnection() else {
                    throw NotchChatError("Gateway monitor에 아직 연결되지 않았습니다.")
                }
                _ = try await client.chatPost(endpoint: endpoint, path: "permission", body: [
                    "sessionId": .string(sessionId),
                    "requestId": .number(Double(permission.requestId)),
                    "optionId": .string(option.id)
                ])
            } catch {
                // The poll cursor is past the request; put the card back so
                // it can still be answered. A chat left meanwhile gets neither.
                guard self.sessionId == sessionId else { return }
                if self.permission == nil { self.permission = permission }
                messages.append(NotchChatMessage(role: .note, text: error.localizedDescription))
            }
        }
    }

    func cancel() {
        guard let sessionId else { return }
        Task {
            guard let (client, endpoint) = await model?.chatConnection() else { return }
            _ = try? await client.chatPost(endpoint: endpoint, path: "cancel", body: ["sessionId": .string(sessionId)])
        }
    }

    /// Short polls while a turn runs: poll's long wait only wakes for
    /// permission requests and status changes, not for streamed text.
    private func startPolling() {
        pollTask?.cancel()
        let started = generation
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                switch await self.pollOnce() {
                case .some(true): failures = 0
                case .some(false): return
                case .none:
                    // A blip retries with backoff; a lasting failure ends the
                    // turn's view instead of spinning forever.
                    failures += 1
                    // Left for another chat meanwhile: that chat is not this one's to clear.
                    guard !Task.isCancelled, started == self.generation else { return }
                    if failures >= 5 {
                        self.status = nil
                        self.activity = nil
                        self.messages.append(NotchChatMessage(role: .note, text: "세션 상태를 더 받아오지 못했습니다. 세션 상세에서 확인하세요."))
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(failures) * 1_000_000_000)
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    /// true: keep polling; false: the turn is over; nil: this poll failed.
    private func pollOnce() async -> Bool? {
        guard let sessionId, !Task.isCancelled else { return false }
        // The same session reattached in a new chat is a new conversation:
        // a reply to the old one's poll must not land in it.
        let started = generation
        guard let (client, endpoint) = await model?.chatConnection() else { return nil }
        do {
            let reply = try await client.chatPoll(endpoint: endpoint, sessionId: sessionId, cursor: cursor, waitMs: 0)
            guard !Task.isCancelled, started == generation, sessionId == self.sessionId, let root = reply.objectValue else { return false }
            cursor = root["nextCursor"]?.intValue ?? cursor
            status = root["status"]?.stringValue
            for event in root["events"]?.arrayValue ?? [] {
                guard let event = event.objectValue else { continue }
                if event["type"]?.stringValue == "permission_request" { permission = Self.permission(from: event) }
                if event["type"]?.stringValue == "permission_response" { permission = nil }
                if event["type"]?.stringValue?.hasPrefix("tool_call") == true,
                   let title = event["title"]?.stringValue ?? event["toolCall"]?.objectValue?["title"]?.stringValue {
                    activity = title
                }
            }
            // The card goes with a response or the end of the turn, not with a
            // status that has not caught up with the request yet.
            if !isRunning { permission = nil }
            if let text = root["result"]?.objectValue?["text"]?.stringValue, !text.isEmpty,
               let last = messages.indices.last, messages[last].role == .agent {
                messages[last].text = text
            }
            if !isRunning { activity = nil }
            return isRunning
        } catch {
            return nil
        }
    }

    private static func permission(from event: [String: JSONValue]) -> NotchChatPermission? {
        guard let requestId = event["requestId"]?.intValue else { return nil }
        let toolCall = event["toolCall"]?.objectValue
        let title = toolCall?["title"]?.stringValue ?? toolCall?["kind"]?.stringValue ?? "도구 실행"
        let options = (event["options"]?.arrayValue ?? []).compactMap { value -> NotchChatPermission.Option? in
            guard let option = value.objectValue, let id = option["optionId"]?.stringValue else { return nil }
            return .init(id: id, name: option["name"]?.stringValue ?? id, kind: option["kind"]?.stringValue ?? "")
        }
        return NotchChatPermission(requestId: requestId, title: title, options: options)
    }
}

extension Notification.Name {
    /// Show Settings on the 표시 요소 tab (handled by AppModel).
    static let openSurfacesSettings = Notification.Name("AgenLynk.openSurfacesSettings")
    /// object: the session ID whose detail window should open.
    static let openSessionDetail = Notification.Name("AgenLynk.openSessionDetail")
}

struct NotchChatError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Panel

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel that hangs from the notch: a pill the width of the notch
/// while collapsed, the chat when expanded.
@MainActor
final class NotchChatController: NSObject, ObservableObject {
    enum Page { case sessions, chat }

    @Published private(set) var expanded = false
    /// Expanded, the notch shows the session cards; the chat is one of them.
    @Published var page: Page = .sessions
    /// A Frontdoor alert popping out of the collapsed notch.
    @Published private(set) var alert: NotchAlert?
    let store: NotchChatStore
    private weak var model: AppModel?
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var tracker = FrontdoorAlertTracker()
    private var modelSubscription: AnyCancellable?
    private var alertDismissal: Task<Void, Never>?
    /// The app that had the keyboard before the notch opened.
    private var previousApp: NSRunningApplication?
    /// Alerts that arrived while a reply box was open.
    @Published private var queued: [NotchAlert] = []
    private var settingsSubscriptions: Set<AnyCancellable> = []
    private var settings: AppSettings? { model?.settings }
    var repliesEnabled: Bool { settings?.notchRepliesEnabled ?? true }
    private(set) var notchSize = CGSize(width: 200, height: 32)

    static let expandedSize = CGSize(width: 440, height: 520)
    static let alertHeight: CGFloat = 62
    static let replyHeight: CGFloat = 108

    init(model: AppModel) {
        self.model = model
        store = NotchChatStore(model: model)
        super.init()
        // Monitor state arrives in bursts; reading Frontdoors at most every
        // 300 ms keeps this off the hot path. A throttle, not a debounce: a
        // streaming reply changes the model several times a second, and a
        // debounce that never settles never showed the alert at all.
        modelSubscription = model.objectWillChange
            .throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshAlerts() }
        // Settings → 표시 요소: the notch itself, and whether a Frontdoor
        // waits for a reply (only while the notch is there to take it).
        model.settings.$notchEnabled.dropFirst().removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled, let model = self.model {
                    // Changes made while the notch was off are not news now.
                    _ = self.tracker.update(model.frontdoorSessions)
                }
                enabled ? self.show() : self.hide()
                self.pushReplySetting(notchEnabled: enabled)
            }
            .store(in: &settingsSubscriptions)
        model.settings.$notchRepliesEnabled.dropFirst().removeDuplicates()
            .sink { [weak self] enabled in self?.pushReplySetting(repliesEnabled: enabled) }
            .store(in: &settingsSubscriptions)
        model.settings.$notchAlertsEnabled.dropFirst().removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, !enabled, self.alert?.reply == nil else { return }
                self.queued.removeAll { $0.reply == nil }
                self.dismissAlert()
            }
            .store(in: &settingsSubscriptions)
    }

    private func refreshAlerts() {
        // With the notch off nothing can show an alert: skip the work (and
        // the sounds) instead of tracking Frontdoors for a hidden panel.
        guard let model, model.settings.notchEnabled else { return }
        let frontdoors = model.frontdoorSessions
        let alerts = tracker.update(frontdoors)
        // A wait that was answered elsewhere takes its alert with it.
        let stillWaiting = { (alert: NotchAlert) -> Bool in
            let phase = frontdoors.first { $0.id == alert.frontdoorId }.map(FrontdoorPhase.of)
            return phase == .waitingPermission || phase == .waitingInput
        }
        queued.removeAll { $0.reply == nil && $0.isSticky && !stillWaiting($0) }
        if let current = alert, current.isSticky, current.reply == nil, !stillWaiting(current) { dismissAlert() }
        // A Frontdoor already offering a reply box says "done" there.
        let replying = ([alert].compactMap { $0 } + queued).filter { $0.reply != nil }
        let fresh = alerts.filter { next in
            !(next.kind == .done && replying.contains { $0.frontdoorId == next.frontdoorId || $0.sessionId == next.sessionId })
        }
        // A wait is shown at once. "Done" and "failed" wait a moment and are
        // shown only if the Frontdoor is still at rest: a status that dips to
        // idle between steps (or a reply that set it going again) is not news.
        for sticky in fresh where sticky.isSticky { present(sticky) }
        for ended in fresh where !ended.isSticky { confirmEnded(ended) }
    }

    private func confirmEnded(_ ended: NotchAlert) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, let model = self.model,
                  let frontdoor = model.frontdoorSessions.first(where: { $0.id == ended.frontdoorId }) else { return }
            let phase = FrontdoorPhase.of(frontdoor)
            guard (ended.kind == .done && phase == .idle) || (ended.kind == .failed && phase == .failed) else { return }
            self.present(ended)
        }
    }

    /// `reply_slot` / `reply_slot_closed` from the sidecar: a finished
    /// Frontdoor that is listening for a reply, and the end of that window.
    func handleReplyMessage(kind: String, message: [String: JSONValue]) {
        if kind == "reply_slot_closed" {
            guard let id = message["id"]?.stringValue else { return }
            queued.removeAll { $0.reply?.id == id }
            if alert?.reply?.id == id { dismissAlert(release: false) }
            return
        }
        guard let slot = message["slot"]?.objectValue,
              let id = slot["id"]?.stringValue,
              let sessionId = slot["sessionId"]?.stringValue else { return }
        // Resent on every reconnect: one already showing or waiting is kept.
        if alert?.reply?.id == id || queued.contains(where: { $0.reply?.id == id }) { return }
        let frontdoor = model?.frontdoorSessions.first { frontdoor in
            FrontdoorPhase.members(frontdoor).contains { $0.sessionId == sessionId }
        }
        let cwd = slot["cwd"]?.stringValue
        let expiresMs = slot["expiresAt"]?.doubleValue ?? (Date().timeIntervalSince1970 + 20) * 1000
        present(NotchAlert(
            kind: .done,
            frontdoorId: frontdoor?.id ?? sessionId,
            sessionId: sessionId,
            provider: slot["provider"]?.stringValue ?? frontdoor?.provider ?? "claude",
            title: frontdoor?.displayName ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Frontdoor",
            reply: NotchReplySlot(
                id: id,
                lastMessage: slot["lastMessage"]?.stringValue,
                expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
                backgroundTasks: slot["backgroundTasks"]?.intValue ?? 0
            )
        ))
        #if DEBUG
        // Debug-only end-to-end check: snapshot the reply box, then answer.
        let environment = ProcessInfo.processInfo.environment
        if let text = environment["ACP_LYNK_NOTCH_DEMO_AUTOREPLY"], !Self.demoReplied {
            Self.demoReplied = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let dir = environment["ACP_LYNK_NOTCH_DEMO_DIR"] {
                    self?.snapshot(to: "\(dir)/reply-\(slot["provider"]?.stringValue ?? "agent").png")
                }
                self?.sendReply(text)
            }
        }
        #endif
    }

    /// The monitor stream (re)connected. The sidecar resends the reply
    /// windows still open (deduplicated above); one lost with a restarted
    /// sidecar runs out on its own deadline. The reply setting is pushed
    /// again because a new sidecar starts with its default.
    func streamConnected() {
        pushReplySetting()
    }

    func setRepliesEnabled(_ enabled: Bool) {
        settings?.notchRepliesEnabled = enabled
    }

    /// Values passed in come from a publisher's willSet, before the setting
    /// itself has changed.
    private func pushReplySetting(notchEnabled: Bool? = nil, repliesEnabled: Bool? = nil) {
        let enabled = (notchEnabled ?? settings?.notchEnabled ?? true) && (repliesEnabled ?? self.repliesEnabled)
        Task { [weak self] in
            guard let (client, endpoint) = await self?.model?.chatConnection() else { return }
            _ = try? await client.postJSON(endpoint: endpoint, path: "api/notch/reply-settings", body: ["enabled": .bool(enabled)])
        }
    }

    func sendReply(_ text: String) {
        guard let current = alert, let slot = current.reply else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dismissAlert(release: false)
        Task { [weak self] in
            let delivered = await self?.replyAction(slot.id, ["action": .string("answer"), "text": .string(trimmed)])
            guard let self, delivered != true else { return }
            // Not delivered while the Frontdoor still waits: give the box
            // back instead of leaving it waiting for nothing.
            if slot.expiresAt > Date() {
                self.present(current)
                return
            }
            self.present(NotchAlert(
                kind: .failed, frontdoorId: current.frontdoorId, sessionId: current.sessionId,
                provider: current.provider, title: current.title,
                note: "답장을 전달하지 못했어요 · 대기 시간이 끝났을 수 있어요"
            ))
        }
    }

    /// The person is typing: keep the Frontdoor waiting (throttled by the row).
    func extendReply() {
        guard let slot = alert?.reply else { return }
        Task { [weak self] in
            guard let (client, endpoint) = await self?.model?.chatConnection(),
                  let answer = try? await client.postJSON(endpoint: endpoint, path: "api/notch/reply", body: [
                      "action": .string("extend"), "id": .string(slot.id)
                  ]),
                  let expiresMs = answer.objectValue?["slot"]?.objectValue?["expiresAt"]?.doubleValue,
                  let self, var current = self.alert, current.reply?.id == slot.id else { return }
            current.reply = NotchReplySlot(
                id: slot.id, lastMessage: slot.lastMessage,
                expiresAt: Date(timeIntervalSince1970: expiresMs / 1000), backgroundTasks: slot.backgroundTasks
            )
            self.alert = current
            self.armReplyExpiry(current)
        }
    }

    /// Whether the sidecar took the action (false when the slot was gone).
    @discardableResult
    private func replyAction(_ id: String, _ body: [String: JSONValue]) async -> Bool {
        guard let (client, endpoint) = await model?.chatConnection() else { return false }
        var body = body
        body["id"] = .string(id)
        let answer = try? await client.postJSON(endpoint: endpoint, path: "api/notch/reply", body: body)
        return answer?.objectValue?["ok"]?.boolValue == true
    }

    private func release(_ slot: NotchReplySlot) {
        Task { [weak self] in await self?.replyAction(slot.id, ["action": .string("dismiss")]) }
    }

    func present(_ next: NotchAlert) {
        // An open reply box is never pushed aside: whatever else happens
        // waits its turn, so a half-typed reply is not lost.
        // With alerts off only a reply box still shows: it is how a reply
        // is given, and replies have their own switch.
        if next.reply == nil, settings?.notchAlertsEnabled == false { return }
        // A hidden notch shows no alert and plays no sound.
        if settings?.notchEnabled == false { return }
        if let current = alert {
            // An open reply box, or a wait the person has not answered yet,
            // is never pushed aside: the newcomer queues behind it. The same
            // Frontdoor's own newer alert replaces it.
            let replyOpen = current.reply != nil && next.reply?.id != current.reply?.id
            let waitOpen = current.isSticky && current.reply == nil && current.frontdoorId != next.frontdoorId
            if replyOpen || waitOpen {
                queued.removeAll { $0.frontdoorId == next.frontdoorId && $0.reply == nil && next.reply == nil }
                queued.append(next)
                pruneQueue()
                return
            }
        }
        alertDismissal?.cancel()
        alert = next
        if settings?.notchSoundsEnabled != false { NSSound(named: next.isSticky ? "Glass" : "Pop")?.play() }
        if !expanded { layout(animated: true) }
        if next.reply != nil {
            armReplyExpiry(next)
        } else if !next.isSticky {
            alertDismissal = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.dismissAlert()
            }
        }
    }

    /// What waits behind an open alert stays current and bounded: a wait
    /// nobody answers would otherwise collect every Frontdoor's "done" and
    /// every expired reply box behind it for as long as it lasts.
    private func pruneQueue(now: Date = Date()) {
        queued.removeAll { alert in
            if let slot = alert.reply { return slot.expiresAt < now }
            return !alert.isSticky && now.timeIntervalSince(alert.createdAt) > 30
        }
        while queued.count > Self.maxQueuedAlerts {
            queued.remove(at: queued.firstIndex(where: { !$0.isSticky }) ?? 0)
        }
    }

    private static let maxQueuedAlerts = 20

    /// The app's own deadline, so a lost close message cannot leave a dead
    /// reply box on screen.
    private func armReplyExpiry(_ current: NotchAlert) {
        guard let slot = current.reply else { return }
        alertDismissal?.cancel()
        alertDismissal = Task { [weak self] in
            let wait = max(0, slot.expiresAt.timeIntervalSinceNow) + 3
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, self?.alert?.reply?.id == slot.id else { return }
            // Closed on the sidecar too: an extend that landed late must not
            // keep the agent waiting behind a box that is gone.
            self?.dismissAlert(release: true)
        }
    }

    /// `release` lets a Frontdoor waiting for a reply stop right away.
    func dismissAlert(release: Bool = true) {
        alertDismissal?.cancel()
        guard let current = alert else { return }
        if release, let slot = current.reply { self.release(slot) }
        alert = nil
        // Waiting ones first; a "done" that sat in the queue too long is old
        // news, and so is a reply box whose window closed meanwhile.
        pruneQueue()
        if let next = queued.firstIndex(where: \.isSticky) ?? queued.indices.last {
            present(queued.remove(at: next))
        } else if !expanded {
            layout(animated: true)
        }
    }

    /// Sessions whose Stop is held open for a notch reply right now.
    var replyingSessionIds: Set<String> {
        let now = Date()
        return Set(([alert].compactMap { $0 } + queued)
            .filter { ($0.reply?.expiresAt).map { $0 > now } ?? false }
            .compactMap(\.sessionId))
    }

    /// The notch is not part of a SwiftUI scene, so it cannot use the
    /// Settings scene's opener; it shows the same view in its own window.
    static func openSettings() {
        NotificationCenter.default.post(name: .openSurfacesSettings, object: nil)
    }

    func expandToSessions() {
        page = .sessions
        expand()
    }

    /// The live session an alert is about.
    private func session(for alert: NotchAlert) -> GatewaySession? {
        guard let sessionId = alert.sessionId else { return nil }
        return model?.sessions.first { $0.sessionId == sessionId }
    }

    func canJump(to alert: NotchAlert) -> Bool { SessionWindowJumper.canJump(session(for: alert)) }

    func jumpToWindow(of alert: NotchAlert) {
        guard let session = session(for: alert) else { return }
        SessionWindowJumper.jump(to: session)
    }

    func openChat(new: Bool) {
        if new { store.newChat() }
        page = .chat
        if !expanded { expand() }
    }

    func openAlert() {
        guard let alert else { return }
        // Looking at the session must not answer for the person: a reply box
        // stays open (and the Frontdoor keeps waiting) while they read.
        if alert.reply == nil { dismissAlert() }
        if let sessionId = alert.sessionId {
            NotificationCenter.default.post(name: .openSessionDetail, object: sessionId)
        }
    }

    func show() {
        let first = panel == nil
        if first { makePanel() }
        layout(animated: false)
        panel?.orderFrontRegardless()
        #if DEBUG
        if first { runDemoIfRequested() }
        #endif
    }

    func hide() {
        // What was showing or waiting is not news once the notch comes back:
        // the tracker re-baselines then, and every reply box, shown or
        // queued, lets its agent go.
        for slot in queued.compactMap(\.reply) { release(slot) }
        queued.removeAll()
        dismissAlert(release: true)
        collapse()
        panel?.orderOut(nil)
        // Let the panel go: hidden, it went on re-rendering its root view on
        // every model change. show() builds a new one.
        panel?.contentView = nil
        panel = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func toggle() {
        if panel == nil || panel?.isVisible == false { show() }
        expanded ? collapse() : expand()
    }

    func expand() {
        if !expanded, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        expanded = true
        layout(animated: true)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    /// `restoreFocus`: the person closed the notch (Esc, chevron), so the app
    /// they were typing in gets the keyboard back.
    func collapse(restoreFocus: Bool = false) {
        expanded = false
        layout(animated: true)
        if restoreFocus, let app = previousApp, !app.isTerminated {
            panel?.resignKey()
            app.activate()
        }
        previousApp = nil
    }

    #if DEBUG
    private static var demoReplied = false

    /// Debug-only demo for checking the panel without screen recording:
    /// ACP_LYNK_NOTCH_DEMO_DIR=<dir> sends ACP_LYNK_NOTCH_DEMO_PROMPT to
    /// ACP_LYNK_NOTCH_DEMO_PROVIDER and writes the panel as PNGs into <dir>.
    func runDemoIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let dir = environment["ACP_LYNK_NOTCH_DEMO_DIR"],
              environment["ACP_LYNK_NOTCH_DEMO_AUTOREPLY"] == nil else { return }
        if environment["ACP_LYNK_NOTCH_DEMO_TIMELINE"] != nil {
            // Every 0.5 s for 2 minutes: when each root's status changes as the app sees it.
            Task { @MainActor in
                var last: [String: String] = [:]
                var lines: [String] = []
                let start = Date()
                while Date().timeIntervalSince(start) < 120 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let model else { continue }
                    for session in model.sessions where session.isFrontdoorRecord {
                        let value = "\(session.status) cwd=\((session.cwd as NSString).lastPathComponent)"
                        if last[session.sessionId] != value {
                            last[session.sessionId] = value
                            lines.append("\(ISO8601DateFormatter().string(from: Date())) \(session.sessionId.suffix(12)) \(value)")
                            try? lines.joined(separator: "\n").write(toFile: "\(dir)/timeline.txt", atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
            return
        }
        if let dumpAfter = environment["ACP_LYNK_NOTCH_DEMO_DUMP"].flatMap(UInt64.init) {
            // The Frontdoor groups the notch shows, member by member, after
            // `dumpAfter` seconds (alongside any other demo).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: dumpAfter * 1_000_000_000)
                guard let model else { return }
                let rows: [[String: Any]] = model.frontdoorSessions.map { frontdoor in
                    [
                        "id": frontdoor.id, "name": frontdoor.displayName, "provider": frontdoor.provider,
                        "phase": "\(FrontdoorPhase.of(frontdoor))",
                        "members": frontdoor.members.map { session -> [String: Any] in [
                            "sessionId": session.sessionId, "role": session.role, "source": session.source,
                            "provider": session.provider, "status": session.status, "cwd": session.cwd,
                            "title": session.title ?? "", "opener": session.opener ?? "",
                            "openerInstanceId": session.openerInstanceId ?? "",
                            "parent": session.parentSessionId ?? "", "created": session.createdAt ?? "",
                            "updated": session.updatedAt ?? ""
                        ] }
                    ]
                }
                if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: "\(dir)/frontdoors.json"))
                }
            }
        }
        if let shots = environment["ACP_LYNK_NOTCH_DEMO_SESSIONS"], let count = Int(shots) {
            // The sessions page and the collapsed pill, every 5 s.
            Task { @MainActor in
                for index in 0..<count {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    collapse()
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    snapshot(to: "\(dir)/pill-\(index).png")
                    page = .sessions
                    expand()
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    snapshot(to: "\(dir)/sessions-\(index).png")
                }
            }
            return
        }
        if environment["ACP_LYNK_NOTCH_DEMO_ALERT"] != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                present(NotchAlert(kind: .permission, frontdoorId: "demo", sessionId: nil, provider: "claude", title: "AgenLynk"))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                snapshot(to: "\(dir)/alert-permission.png")
                present(NotchAlert(kind: .done, frontdoorId: "demo", sessionId: nil, provider: "codex", title: "agent_gateway"))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                snapshot(to: "\(dir)/alert-done.png")
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            snapshot(to: "\(dir)/1-collapsed.png")
            store.provider = environment["ACP_LYNK_NOTCH_DEMO_PROVIDER"] ?? "claude"
            for _ in 0..<60 where store.owner == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            openChat(new: false)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            snapshot(to: "\(dir)/2-expanded.png")
            store.draft = environment["ACP_LYNK_NOTCH_DEMO_PROMPT"] ?? "안녕! 한 문장으로 자기소개해줘."
            store.send()
            var shotRunning = false
            for _ in 0..<180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if store.isRunning, !shotRunning, store.messages.last?.text.isEmpty == false {
                    snapshot(to: "\(dir)/3-running.png")
                    shotRunning = true
                }
                if !store.busy, !store.isRunning, store.messages.contains(where: { $0.role == .agent && !$0.text.isEmpty }) { break }
                if store.messages.last?.role == .note { break }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            snapshot(to: "\(dir)/4-answered.png")
            guard let sessionId = store.sessionId else { return }
            NotificationCenter.default.post(name: .openSessionDetail, object: sessionId)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("session-detail") == true }),
               let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/5-session-detail.png"))
            }
        }
    }

    private func snapshot(to path: String) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif

    private func makePanel() {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        guard let model else { return }
        panel.contentView = NSHostingView(rootView: NotchChatRootView(model: model, controller: self, store: store))
        self.panel = panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.expanded, event.window === self.panel else { return event }
            self.collapse(restoreFocus: true)
            return nil
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    @objc private func screensChanged() {
        layout(animated: false)
    }

    private func layout(animated: Bool) {
        guard let panel, let screen = Self.notchScreen() else { return }
        notchSize = Self.notchSize(of: screen)
        let size = expanded
            ? Self.expandedSize
            : alert != nil
                ? CGSize(
                    width: max(notchSize.width + 72, alert?.reply == nil ? 380 : 460),
                    height: notchSize.height + Self.alertHeight + (alert?.reply == nil ? 0 : Self.replyHeight)
                )
                : CGSize(width: notchSize.width + 72, height: notchSize.height)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true, animate: animated)
    }

    private static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// The notch's real size; a screen without one gets a menu-bar-high
    /// strip so the pill still sits at the top center.
    private static func notchSize(of screen: NSScreen) -> CGSize {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width {
            return CGSize(width: screen.frame.width - left - right, height: top)
        }
        return CGSize(width: 160, height: NSStatusBar.system.thickness)
    }
}

// MARK: - Views

private struct NotchChatRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: NotchChatController
    @ObservedObject var store: NotchChatStore

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(radius: controller.expanded ? 22 : 12)
                .fill(Color.black)
            if controller.expanded {
                Group {
                    if controller.page == .chat {
                        NotchChatExpandedView(model: model, controller: controller, store: store)
                    } else {
                        NotchSessionsView(model: model, controller: controller, store: store)
                    }
                }
                .padding(.top, controller.notchSize.height + 6)
                .padding([.horizontal, .bottom], 14)
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    collapsedPill
                    if let alert = controller.alert {
                        NotchAlertRow(alert: alert, controller: controller)
                            .id(alert.id)
                            .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: controller.alert)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// Left of the notch: the most urgent Frontdoor's provider and state;
    /// right: how many need the person, and how many are running.
    private var collapsedPill: some View {
        let pipeline = model.menuBarPipeline.notchCards
        let top = pipeline.activeCards.first
        return HStack(spacing: 6) {
            // Nothing moving: done for a while after a turn ends, then asleep;
            // re-read every 30 s so the change needs no other update.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let finished = pipeline.idleCards.first { $0.justFinished(now: context.date) }
                ProviderOrb(
                    provider: top?.frontdoor.provider ?? finished?.frontdoor.provider ?? store.sessionProvider ?? store.provider,
                    size: max(18, controller.notchSize.height * 0.82),
                    mood: top.map { AgentMascot.Mood(urgency: $0.urgency) }
                        ?? (store.isRunning ? .working : finished != nil ? .happy : .idle),
                    still: true
                )
            }
            if let top {
                NotchStatusBadge(style: NotchStatusStyle(urgency: top.urgency, currentStep: top.focus?.currentStep), showsLabel: false)
            }
            Spacer()
            let waiting = pipeline.permissionCount + pipeline.inputCount + (store.permission == nil ? 0 : 1)
            if waiting > 0 {
                NotchStatusBadge(style: NotchStatusStyle(urgency: .permission), showsLabel: false)
                Text("\(waiting)").font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(.orange)
            }
            // Working Frontdoors / their working Workers, as in the menu bar.
            let counts = MenuBarCounts(pipeline)
            if counts.main > 0 || counts.sub > 0 {
                Text("\(counts.main)/\(counts.sub)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("작업 중 Frontdoor \(counts.main)개 / Worker \(counts.sub)개")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: controller.notchSize.height)
        .contentShape(Rectangle())
        .onTapGesture { controller.expand() }
    }
}

private struct NotchChatExpandedView: View {
    /// Observed so the Frontdoor picker follows the live Frontdoor list.
    @ObservedObject var model: AppModel
    @ObservedObject var controller: NotchChatController
    @ObservedObject var store: NotchChatStore
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            if let alert = controller.alert {
                NotchAlertRow(alert: alert, controller: controller)
                    .id(alert.id)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity))
            }
            messageList
            if store.isRunning, let activity = store.activity {
                Label(activity, systemImage: "gearshape.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let permission = store.permission { permissionCard(permission) }
            input
        }
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { controller.page = .sessions } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("세션 목록")
            ProviderOrb(provider: store.sessionProvider ?? store.provider, size: 30, active: store.isRunning)
            if store.sessionId == nil {
                Picker("", selection: $store.provider) {
                    ForEach(NotchChatStore.providers, id: \.self) { Text(providerDisplayLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            } else {
                Text(providerDisplayLabel(store.sessionProvider ?? store.provider)).font(.headline)
                if let status = store.status { Text(NotchStatusStyle(status: status).label).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let sessionId = store.sessionId {
                Button { openDetail(sessionId) } label: { Image(systemName: "list.bullet.rectangle") }
                    .buttonStyle(.borderless)
                    .help("세션 상세 보기")
            }
            Menu {
                Button("새 채팅") { store.newChat() }
                Button("표시 요소 설정…") { NotchChatController.openSettings() }
                Toggle("끝난 Frontdoor에 노치에서 답장", isOn: Binding(
                    get: { controller.repliesEnabled },
                    set: { controller.setRepliesEnabled($0) }
                ))
                Button("작업 폴더 선택…") { chooseFolder() }
                let sessions = store.attachableSessions
                if !sessions.isEmpty {
                    Divider()
                    Section("Gateway 세션에 연결") {
                        ForEach(sessions) { session in
                            Button("\(session.providerLabel) · \(session.displayName)") { store.attach(session) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { controller.collapse(restoreFocus: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.messages.isEmpty {
                        ownerPicker
                        Text("작업 폴더: \((store.cwd as NSString).abbreviatingWithTildeInPath)\n구독 로그인으로 \(providerDisplayLabel(store.provider)) Worker를 열어 이 Frontdoor 아래에 붙입니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.messages) { message in
                        bubble(message).id(message.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.messages) { _, messages in
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Which Frontdoor the new chat's Worker belongs to.
    @ViewBuilder
    private var ownerPicker: some View {
        let owners = store.owners
        if owners.isEmpty {
            Label("채팅을 맡길 Frontdoor가 없어요", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Picker("Frontdoor", selection: Binding(
                get: { store.owner?.root?.sessionId ?? "" },
                set: { store.ownerId = $0 }
            )) {
                ForEach(owners) { frontdoor in
                    Text("\(providerDisplayLabel(frontdoor.provider)) · \(frontdoor.displayName)")
                        .tag(frontdoor.root?.sessionId ?? "")
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            .fixedSize()
            // What the picker shows is the choice: if that Frontdoor goes away
            // before sending, the chat says so instead of moving to another.
            .onAppear { if store.ownerId == nil { store.ownerId = store.owner?.root?.sessionId } }
        }
    }

    @ViewBuilder
    private func bubble(_ message: NotchChatMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .textSelection(.enabled)
                .padding(8)
                .background(Color.accentColor.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            Group {
                if message.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(LocalizedStringKey(message.text)).textSelection(.enabled)
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
        case .note:
            Text(message.text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func permissionCard(_ permission: NotchChatPermission) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(permission.title, systemImage: "lock.shield").font(.callout).lineLimit(2)
            // Side by side when they fit, stacked when the options are many.
            ViewThatFits(in: .horizontal) {
                HStack { permissionButtons(permission) }
                VStack(alignment: .leading) { permissionButtons(permission) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func permissionButtons(_ permission: NotchChatPermission) -> some View {
        ForEach(permission.options) { option in
            Button(option.name) { store.answer(option) }
                .tint(option.kind.hasPrefix("allow") ? .green : .red)
        }
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField("메시지", text: $store.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { store.send() }
                .padding(8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            if store.isRunning {
                Button { store.cancel() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
            } else {
                Button { store.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(store.busy || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The session window is a SwiftUI scene; this panel is not, so it asks
    /// the menu bar label (always on screen) to open it.
    private func openDetail(_ sessionId: String) {
        controller.collapse()
        NotificationCenter.default.post(name: .openSessionDetail, object: sessionId)
    }

    private func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.directoryURL = URL(fileURLWithPath: store.cwd)
        if open.runModal() == .OK, let url = open.url { store.customCwd = url.path }
    }
}

/// One Frontdoor alert: who, what it needs, and a tap to open the session.
/// A Frontdoor still listening gets its last answer and a reply box.
///
/// `@MainActor` on the type: the controller is a plain `let`, so nothing else
/// isolates the helpers that call it, and the macOS 14 SDK isolates only
/// `body` (CI builds with it).
@MainActor
struct NotchAlertRow: View {
    let alert: NotchAlert
    let controller: NotchChatController
    @State private var draft = ""
    @State private var lastExtended: Date?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let slot = alert.reply { replyBox(slot) }
        }
    }

    private func replyBox(_ slot: NotchReplySlot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let last = slot.lastMessage, !last.isEmpty {
                Text(last)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("답장 (Enter로 보내기)", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { controller.sendReply(draft) }
                    .onChange(of: draft) { _, value in
                        // Keep the window open while typing, at most every 5 s.
                        guard !value.isEmpty, lastExtended.map({ Date().timeIntervalSince($0) > 5 }) ?? true else { return }
                        lastExtended = Date()
                        controller.extendReply()
                    }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(max(0, Int(slot.expiresAt.timeIntervalSince(context.date))))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button { controller.sendReply(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: NotchChatController.replyHeight, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderOrb(provider: alert.provider, size: 46, mood: alertMood)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(alert.message).font(.caption).foregroundStyle(tint).lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            if controller.canJump(to: alert) {
                Button { controller.jumpToWindow(of: alert) } label: { Image(systemName: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless)
                    .help("이 세션이 실행 중인 창으로 이동")
            }
            Button { controller.openAlert() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .help("세션 상세")
            Button { controller.dismissAlert() } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: NotchChatController.alertHeight)
        .contentShape(Rectangle())
        // Opens the notch around it (the reply box gets room) instead of
        // closing it.
        .onTapGesture { if !controller.expanded { controller.expandToSessions() } }
    }

    private var alertMood: AgentMascot.Mood {
        switch alert.kind {
        case .permission, .input: .waiting
        case .done: alert.reply == nil ? .happy : .waiting
        case .failed: .failed
        }
    }

    private var icon: String {
        if alert.reply != nil { return "arrowshape.turn.up.left.fill" }
        return switch alert.kind {
        case .permission: "lock.shield.fill"
        case .input: "questionmark.bubble.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        if alert.reply != nil { return .teal }
        return switch alert.kind {
        case .permission, .input: .orange
        case .done: .green
        case .failed: .red
        }
    }
}

/// The provider's mascot (AgentMascot); it moves while a turn runs. `mood`
/// overrides what `active` alone says.
struct ProviderOrb: View {
    let provider: String
    var size: CGFloat
    var active = false
    var mood: AgentMascot.Mood?
    /// No resting motion: for the always-visible collapsed pill, where a
    /// breathing 20pt mascot is barely visible but would animate all day.
    var still = false
    /// The look chosen for the pet (devil or mermaid) is the notch's too.
    @AppStorage("monitor.petStyle") private var petStyle = PetStyle.orbit.rawValue

    var body: some View {
        IsolatedMascot(spec: .init(
            provider: provider, size: size, mood: mood ?? (active ? .working : .idle),
            kind: (PetStyle(stored: petStyle) ?? .orbit).mascotKind, still: still
        ))
        .frame(width: size, height: size)
    }
}

/// A hosting view that is drawn but never clicked: taps on the mascot fall
/// through to the pill or card around it.
private final class PassThroughHostingView: NSHostingView<AgentMascot> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The mascot in a hosting view of its own. Inside the notch's one big
/// NSHostingView, every animation frame of a mascot made AppKit lay out the
/// whole panel (cards, pipeline and all): a panel-sized tree with one moving
/// mascot cost ~15% CPU, the same mascot isolated ~3.6%. The child view's
/// size is fixed by the parent frame, so its frames stay inside it.
private struct IsolatedMascot: NSViewRepresentable {
    struct Spec: Equatable {
        let provider: String
        let size: CGFloat
        let mood: AgentMascot.Mood
        let kind: AgentMascot.Kind
        let still: Bool

        var mascot: AgentMascot {
            AgentMascot(provider: provider, size: size, mood: mood, kind: kind, still: still)
        }
    }

    let spec: Spec

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSHostingView<AgentMascot> {
        let view = PassThroughHostingView(rootView: spec.mascot)
        view.sizingOptions = []
        context.coordinator.spec = spec
        return view
    }

    func updateNSView(_ view: NSHostingView<AgentMascot>, context: Context) {
        // The parent re-renders on every stream message; only a real change
        // reaches the mascot.
        guard context.coordinator.spec != spec else { return }
        context.coordinator.spec = spec
        view.rootView = spec.mascot
    }

    final class Coordinator {
        var spec: IsolatedMascot.Spec?
    }
}

/// Square top corners flush with the screen edge, rounded bottom corners:
/// the shape reads as part of the notch.
private struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
