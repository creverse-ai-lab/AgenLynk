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
}
