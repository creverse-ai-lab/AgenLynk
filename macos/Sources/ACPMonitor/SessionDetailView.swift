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
                    // A streamed response is dozens of chunk events; one row
                    // per fragment reads as noise ("안", "녕", …). Runs collapse
                    // into one row that previews the merged message — the same
                    // collapsing the dashboard's sequence diagram applies.
                    List(collapsedEvents, id: \.event.id, selection: $selectedEventId) { entry in
                        EventRow(
                            event: entry.event,
                            session: session,
                            collapsedCount: entry.count,
                            summaryOverride: entry.count > 1
                                ? mergedChunkBody(for: entry.event, in: events)?.text
                                : nil
                        )
                        .tag(entry.event.id)
                    }
                    .frame(minWidth: 430)
                    ScrollView {
                        if let selectedEvent {
                            EventBodyView(event: selectedEvent, siblings: events).padding(14)
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

    /// Consecutive same-turn chunk runs fold into one row, represented by the
    /// newest fragment (mirrors collapseSequenceEvents in EventSequenceView).
    private var collapsedEvents: [(event: MonitorEvent, count: Int)] {
        var result: [(event: MonitorEvent, count: Int)] = []
        result.reserveCapacity(events.count)
        for event in events {
            if event.type == "agent_message_chunk" || event.type == "agent_thought_chunk",
               let last = result.last,
               last.event.type == event.type,
               last.event.turnId == event.turnId {
                result[result.count - 1] = (event, last.count + 1)
            } else {
                result.append((event, 1))
            }
        }
        return result
    }

    private func sessionHeader(_ session: GatewaySession) -> some View {
        HStack(spacing: 14) {
            Circle().fill(statusColor(session.status)).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName).font(.title3.weight(.semibold))
                Text("\(session.provider) · \(session.model ?? "default") · \(session.status)")
                    .foregroundStyle(.secondary)
                Text(session.cwd).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            Spacer()
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
/// dashboard inspector so both explain an event identically.
struct EventBodyView: View {
    let event: MonitorEvent
    /// The event's whole session bucket. A streamed response is many chunk
    /// events, and whichever single one got selected is just a fragment — with
    /// the bucket in hand the pane can show the message they add up to.
    var siblings: [MonitorEvent] = []
    /// Narrow inspector columns cut long bodies; a full-width pane scrolls
    /// instead and passes nil.
    var characterLimit: Int?
    var bodyFont: Font = .body

    var body: some View {
        let merged = mergedChunkBody(for: event, in: siblings)
        VStack(alignment: .leading, spacing: 10) {
            if let body = merged?.text ?? event.bodyText {
                textBlock(body, font: looksLikeCode(body) ? .system(.caption, design: .monospaced) : bodyFont, label: "본문")
                if let merged {
                    Text("스트림 조각 \(merged.fragments)개를 합쳐 표시 · 원본 JSON은 선택한 조각의 것")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                DisclosureGroup("원본 JSON") {
                    rawPayload.padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                rawPayload
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rawPayload: some View {
        textBlock(event.payload.prettyPrinted, font: .system(.caption, design: .monospaced), label: "JSON")
    }

    private func textBlock(_ text: String, font: Font, label: String) -> some View {
        let shown = characterLimit.map { String(text.prefix($0)) } ?? text
        return VStack(alignment: .leading, spacing: 3) {
            Text(shown)
                .font(font)
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if shown.count < text.count {
                Text("\(label) 미리보기 · 전체 \(text.count.formatted())자")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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
