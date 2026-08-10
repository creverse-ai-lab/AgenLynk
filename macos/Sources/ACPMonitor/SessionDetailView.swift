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
                    List(events, selection: $selectedEventId) { event in
                        EventRow(event: event, session: session).tag(event.id)
                    }
                    .frame(minWidth: 430)
                    ScrollView {
                        if let selectedEvent {
                            Text(selectedEvent.payload.prettyPrinted)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
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
