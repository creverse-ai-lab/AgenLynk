import SwiftUI

// Session names (docs/ux-policy.md §2): the user's name when set, else the
// automatic name. Stored apart from Frontdoor names.
extension AppSettings {
    func sessionName(_ session: GatewaySession) -> String {
        sessionNickname(id: session.sessionId) ?? session.displayName
    }

    func hasSessionNickname(_ session: GatewaySession) -> Bool {
        sessionNickname(id: session.sessionId) != nil
    }

    func setSessionName(_ name: String?, for session: GatewaySession) {
        setSessionNickname(name, id: session.sessionId)
    }
}

/// The session's name with an inline pencil editor. An empty save reverts to
/// the automatic name, like the Frontdoor editor.
struct SessionNameEditor: View {
    @EnvironmentObject private var settings: AppSettings
    let session: GatewaySession
    var font: Font = .title3.weight(.semibold)
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                TextField("이름", text: $draft, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button("저장", action: commit).buttonStyle(.borderless)
                Button("취소") { editing = false }.buttonStyle(.borderless).foregroundStyle(.secondary)
            } else {
                Text(settings.sessionName(session)).font(font).lineLimit(1)
                    .help(session.sessionId)
                Button {
                    draft = settings.sessionName(session)
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("이름 변경")
                if settings.hasSessionNickname(session) {
                    Button {
                        settings.setSessionName(nil, for: session)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("자동 이름으로 되돌리기")
                }
            }
        }
        .onChange(of: session.sessionId) { _, _ in editing = false }
    }

    private func commit() {
        settings.setSessionName(draft, for: session)
        editing = false
    }
}

/// Sheet form of the editor for places without room inline (lane headers).
struct SessionRenameSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let session: GatewaySession
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                ProviderIcon(provider: session.provider, size: 18)
                Text("세션 이름 바꾸기").font(.headline)
            }
            TextField("이름 (비우면 자동 이름)", text: $draft, onCommit: save)
                .textFieldStyle(.roundedBorder)
            Text("자동 이름: \(session.displayName)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("저장", action: save).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { draft = settings.hasSessionNickname(session) ? settings.sessionName(session) : "" }
    }

    private func save() {
        settings.setSessionName(draft, for: session)
        dismiss()
    }
}
