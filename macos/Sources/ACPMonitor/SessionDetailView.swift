import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let sessionId: String?
    @State private var selectedEventId: String?

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                sessionHeader(session)
                Divider()
                sessionConfigPanel(session)
                Divider()
                HSplitView {
                    // One row per canonical event: the sidecar already merged
                    // a streamed response into one message and a tool call's
                    // updates into the call itself.
                    List(events, selection: $selectedEventId) { event in
                        EventRow(event: event, session: session)
                            .tag(event.id)
                    }
                    .frame(minWidth: 430)
                    ScrollView {
                        if let selectedEvent {
                            EventBodyView(event: selectedEvent).padding(14)
                        } else {
                            ContentUnavailableView("이벤트를 선택하세요", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .frame(minWidth: 360)
                }
            }
            .navigationTitle(session.displayName)
            .task(id: sessionId) {
                guard let sessionId, session.role == "worker", !session.isLocalSource else { return }
                await model.loadSessionConfig(sessionId: sessionId)
            }
        } else {
            ContentUnavailableView("세션을 찾을 수 없습니다", systemImage: "questionmark.folder")
        }
    }

    private var session: GatewaySession? { model.sessions.first { $0.sessionId == sessionId } }
    private var events: [MonitorEvent] { model.eventsBySession[sessionId ?? ""] ?? [] }
    private var selectedEvent: MonitorEvent? { events.first { $0.id == selectedEventId } }

    private func sessionHeader(_ session: GatewaySession) -> some View {
        HStack(spacing: 14) {
            Circle().fill(statusColor(session.status)).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName).font(.title3.weight(.semibold))
                Text("\(session.withModel(session.provider)) · \(session.status)")
                    .foregroundStyle(.secondary)
                Text(session.cwd).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            Spacer()
            if let usage = session.usage {
                SessionUsageView(usage: usage, partial: session.usagePartial)
                    .frame(maxWidth: 220)
            }
            VStack(alignment: .trailing) {
                Text("Frontdoor").font(.caption).foregroundStyle(.secondary)
                Text(session.opener ?? "unknown").font(.callout.weight(.medium))
            }
        }
        .padding(16)
    }

    /// Worker-advertised per-session settings (ACP `session/config`). Mutation
    /// is blocked while the session is active or its config is unavailable
    /// (disconnected Worker, load error) — cached values still render so the
    /// panel isn't empty while blocked.
    private func sessionConfigPanel(_ session: GatewaySession) -> some View {
        let supportsSessionConfig = session.role == "worker" && !session.isLocalSource
        let matchesSession = model.sessionConfigSessionId == session.sessionId
        let displayingLoad = supportsSessionConfig && (!matchesSession || model.sessionConfigLoading)
        let unavailableStatus = ["disconnected", "unavailable", "closed"].contains(session.status)
        let mutationBlocked = session.isActive
            || unavailableStatus
            || displayingLoad
            || model.sessionConfigUnavailableReason != nil
            || model.sessionConfigSaving
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("세션 설정", systemImage: "slider.horizontal.below.square.filled.and.square")
                    .font(.callout.weight(.medium))
                if displayingLoad { ProgressView().controlSize(.small) }
                Spacer()
                if session.isActive {
                    Text("세션 실행 중 · 변경 불가").font(.caption).foregroundStyle(.orange)
                }
            }
            if !supportsSessionConfig {
                Text("ACP Worker 세션에서만 조정 가능한 설정을 제공합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if displayingLoad {
                Text("Worker 설정을 불러오는 중입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let reason = model.sessionConfigUnavailableReason {
                Label(reason, systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
            } else if let error = model.sessionConfigError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if model.sessionConfigOptions.isEmpty && !model.sessionConfigLoading {
                Text("이 Worker는 조정 가능한 세션 설정을 제공하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.sessionConfigOptions) { option in
                    SessionConfigRow(
                        option: option,
                        disabled: mutationBlocked,
                        onSelect: { value in
                            Task { await model.setSessionConfig(sessionId: session.sessionId, configId: option.id, value: .string(value)) }
                        },
                        onToggle: { value in
                            Task { await model.setSessionConfig(sessionId: session.sessionId, configId: option.id, value: .bool(value)) }
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One event rendered the way a reader asks about it: what it said first, the
/// raw payload one disclosure away. Shared by the session detail pane and the
/// dashboard inspector so both explain an event identically. `title` and
/// `body` are the sidecar's display text, so nothing is dug out of the JSON.
struct EventBodyView: View {
    let event: MonitorEvent
    /// Narrow inspector columns cut long bodies; a full-width pane scrolls
    /// instead and passes nil.
    var characterLimit: Int?
    var bodyFont: Font = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = event.title, title != event.body {
                Text(title)
                    .font(bodyFont.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let status = eventStatusLabel(event.status) {
                Label(statusLine(status), systemImage: eventSymbol(event))
                    .font(.caption)
                    .foregroundStyle(eventColor(event))
            }
            if let input = event.detail["input"]?.stringValue, event.kind == "tool_call" {
                codeBlock(input, label: "입력")
            }
            if let body = event.body {
                if looksLikeCode(body) {
                    codeBlock(body, label: event.kind == "tool_call" ? "출력" : "본문")
                } else {
                    textBlock(body, font: bodyFont, label: "본문")
                }
            }
            if event.title != nil || event.body != nil {
                DisclosureGroup("원본 JSON") {
                    rawPayload.padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                rawPayload
            }
        }
        // Never wider than the column: a narrow inspector must be able to
        // shrink to it, and a vertical ScrollView keeps its bar at the trailing
        // edge only when its content actually fits that width.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "완료 · 1.2초" when the event says how long it took.
    private func statusLine(_ status: String) -> String {
        guard let milliseconds = event.detail["durationMs"]?.doubleValue else { return status }
        return "\(status) · \(String(format: "%.1f", milliseconds / 1_000))초"
    }

    private var rawPayload: some View {
        codeBlock(event.payload.prettyPrinted, label: "JSON")
    }

    /// Prose: wraps to the available width, so it compresses with the column.
    private func textBlock(_ text: String, font: Font, label: String) -> some View {
        let shown = characterLimit.map { String(text.prefix($0)) } ?? text
        return VStack(alignment: .leading, spacing: 3) {
            Text(shown)
                .font(font)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            previewNote(shown: shown, full: text, label: label)
        }
    }

    /// Code / JSON: its long, unbroken lines would otherwise force the whole
    /// column wide (and push the scrollbar off-screen). Kept on its own lines
    /// and scrolled horizontally inside a width-bounded box instead of wrapping
    /// mid-token, so the column can still shrink to its minimum.
    private func codeBlock(_ text: String, label: String) -> some View {
        let shown = characterLimit.map { String(text.prefix($0)) } ?? text
        return VStack(alignment: .leading, spacing: 3) {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(shown)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                    .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            previewNote(shown: shown, full: text, label: label)
        }
    }

    @ViewBuilder private func previewNote(shown: String, full: String, label: String) -> some View {
        if shown.count < full.count {
            Text("\(label) 미리보기 · 전체 \(full.count.formatted())자")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Tool output, diffs and JSON only stay readable with aligned columns; an
/// agent's prose does not, so it keeps the normal body font.
private func looksLikeCode(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("<") { return true }
    let lines = trimmed.split(separator: "\n")
    guard lines.count > 1 else { return false }
    let structured = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") || $0.hasPrefix("+") || $0.hasPrefix("-") }
    return structured.count * 2 >= lines.count
}

/// A session's token totals and context gauge, shown only for what the source
/// actually reports (every usage field is optional). Shared by the session
/// header and the dashboard inspector.
struct SessionUsageView: View {
    let usage: SessionUsage
    /// The totals cover only the part of a long transcript that was read.
    var partial = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let total = usage.total {
                HStack(spacing: 6) {
                    Text("토큰 \(formatTokenCount(total))\(partial ? "+" : "")")
                        .font(.caption.weight(.medium).monospacedDigit())
                    if let input = usage.inputTokens, let output = usage.outputTokens {
                        Text("입력 \(formatTokenCount(input)) · 출력 \(formatTokenCount(output))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            if let fraction = usage.contextFraction,
               let used = usage.contextUsed,
               let window = usage.contextWindow {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(contextColor(fraction))
                Text("컨텍스트 \(contextPercentText(fraction)) · \(formatTokenCount(used)) / \(formatTokenCount(window))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(partial ? "긴 transcript에서 읽은 부분만 합산한 값입니다." : "")
    }
}

private struct SessionConfigRow: View {
    let option: SessionConfigOption
    let disabled: Bool
    let onSelect: (String) -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(option.name).font(.caption.weight(.medium)).frame(minWidth: 120, alignment: .leading)
            switch option.kind {
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { option.currentValue.boolValue ?? false },
                    set: onToggle
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(disabled)
            case let .select(choices):
                Picker("", selection: Binding(
                    get: { option.currentValue.stringValue ?? choices.first?.value ?? "" },
                    set: onSelect
                )) {
                    ForEach(choices) { choice in
                        Text(choice.groupName.map { "\($0) · \(choice.name)" } ?? choice.name).tag(choice.value)
                    }
                }
                .labelsHidden()
                .disabled(disabled || choices.isEmpty)
                .frame(maxWidth: 220)
            case let .unknown(type):
                Text("지원되지 않는 설정 형식 (\(type))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .opacity(disabled || isUnknownType ? 0.72 : 1)
    }

    private var isUnknownType: Bool {
        if case .unknown = option.kind { return true }
        return false
    }
}
