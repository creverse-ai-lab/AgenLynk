import SwiftUI

/// What turning on the monitoring hooks does, shown before anything is
/// written: during onboarding and, for an existing install, once after the
/// update that introduced them. The same text backs both surfaces.
struct MonitoringConsentChoices: View {
    @Binding var selection: Set<String>
    var disabled = false

    static let choices: [(id: String, label: String, file: String)] = [
        ("claude", "Claude Code", "~/.claude/settings.json"),
        ("codex", "Codex", "~/.codex/hooks.json"),
        ("grok", "Grok", "~/.grok/hooks/agenlynk.json")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.choices, id: \.id) { choice in
                Toggle(isOn: Binding(
                    get: { selection.contains(choice.id) },
                    set: { isOn in
                        if isOn { selection.insert(choice.id) } else { selection.remove(choice.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.label)
                        Text(choice.file)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(disabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("도구 실행·권한 대기·턴 종료를 바로 보여 주도록 위 설정 파일에 AgenLynk hook을 추가합니다. 다른 도구의 hook은 건드리지 않고, 원본은 ~/.acp-gateway/agenlynk/backups에 백업합니다.", systemImage: "doc.badge.gearshape")
                Label("hook은 관찰만 합니다. 도구 이름·입력, 권한 요청, 턴 경계를 이 Mac의 AgenLynk에만 보내고, 에이전트에게 결정을 돌려주지 않습니다.", systemImage: "eye")
                Label("Codex는 새 hook을 처음 실행하기 전에 /hooks에서 승인을 받습니다.", systemImage: "checkmark.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Sheet for an existing user whose AgenLynk update added the hooks.
struct MonitoringConsentSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Set<String> = ["claude", "codex", "grok"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("실시간 모니터링을 켤까요?").font(.title3.weight(.semibold))
            Text("켜지 않아도 transcript로 계속 감지하지만, 권한 대기와 도구 실행이 늦게 보이거나(Claude·Grok은 권한 대기가 보이지 않음) 세션 시작·종료를 놓칠 수 있습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MonitoringConsentChoices(selection: $selection)
            HStack {
                Button("사용 안 함") {
                    Task { await model.answerHookConsent(enabled: []) }
                }
                Spacer()
                Button("나중에") { model.hookConsentPresented = false }
                Button("선택한 CLI 켜기") {
                    Task { await model.answerHookConsent(enabled: selection) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
            Text("설정 > 모니터링에서 언제든 바꿀 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520)
    }
}
