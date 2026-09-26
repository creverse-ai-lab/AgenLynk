import SwiftUI

/// What turning on the monitoring hooks does, shown before anything is
/// written: during onboarding and, for an existing install, once after the
/// update that introduced them. The same text backs both surfaces.
struct MonitoringConsentChoices: View {
    @Binding var selection: Set<String>
    /// CLIs installed on this Mac. Only these can be chosen; the others are
    /// shown so the user knows they can be turned on later.
    var installed: Set<String>
    var disabled = false

    static let choices: [(id: String, label: String, file: String)] = [
        ("claude", "Claude Code", "~/.claude/settings.json"),
        ("codex", "Codex", "~/.codex/hooks.json"),
        ("grok", "Grok", "~/.grok/hooks/agenlynk.json")
    ]

    /// The CLIs whose config directory exists, read the same way the sidecar
    /// does (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`, else the default
    /// directory in the home folder). Used before the sidecar can be asked.
    static func installedCLIs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Set<String> {
        let homes: [(String, String?, String)] = [
            ("claude", environment["CLAUDE_CONFIG_DIR"], ".claude"),
            ("codex", environment["CODEX_HOME"], ".codex"),
            ("grok", environment["GROK_HOME"], ".grok")
        ]
        var present: Set<String> = []
        for (provider, override, directory) in homes {
            let path = (override?.isEmpty == false ? override! : home.appendingPathComponent(directory).path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                present.insert(provider)
            }
        }
        return present
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.choices, id: \.id) { choice in
                let available = installed.contains(choice.id)
                Toggle(isOn: Binding(
                    get: { available && selection.contains(choice.id) },
                    set: { isOn in
                        if isOn { selection.insert(choice.id) } else { selection.remove(choice.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.label)
                        Text(available ? choice.file : "설치되지 않음 — 나중에 설치하면 설정에서 켤 수 있습니다")
                            .font(available ? .caption.monospaced() : .caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(disabled || !available)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("선택한 설정 파일을 백업한 뒤 AgenLynk hook을 추가합니다. 도구 실행·권한 대기·턴 종료를 바로 보여 주기 위한 것이며, 다른 도구의 hook은 건드리지 않습니다. 백업은 ~/.acp-gateway/agenlynk/backups에 있습니다.", systemImage: "doc.badge.gearshape")
                Label("hook은 관찰만 합니다. 도구 이름·입력, 권한 요청, 턴 경계를 이 Mac의 AgenLynk에만 보내고, 에이전트에게 결정을 돌려주지 않습니다.", systemImage: "eye")
                Label("Codex는 새 hook을 처음 실행하기 전에 /hooks에서 승인을 받습니다.", systemImage: "checkmark.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Sheet for an existing user whose AgenLynk update added the hooks, also
/// opened from Settings > 모니터링.
struct MonitoringConsentSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var selectionReady = false

    /// Installed CLIs as the sidecar reports them, else as the file system does.
    private var installed: Set<String> {
        if let status = model.hookStatus, !status.targets.isEmpty {
            return Set(status.targets.filter(\.agentPresent).map(\.provider))
        }
        return MonitoringConsentChoices.installedCLIs()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("실시간 모니터링을 켤까요?").font(.title3.weight(.semibold))
            Text("켜지 않아도 대화 기록 파일로 계속 감지하지만, 권한 대기와 도구 실행이 늦게 보이거나(Claude·Grok은 권한 대기가 보이지 않음) 세션 시작·종료를 놓칠 수 있습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MonitoringConsentChoices(selection: $selection, installed: installed)
            HStack {
                Button("사용 안 함") {
                    Task {
                        await model.answerHookConsent(enabled: [])
                        dismiss()
                    }
                }
                Spacer()
                Button("나중에") {
                    model.hookConsentPresented = false
                    dismiss()
                }
                Button("선택한 CLI 켜기") {
                    let chosen = selection.intersection(installed)
                    Task {
                        await model.answerHookConsent(enabled: chosen)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.intersection(installed).isEmpty)
            }
            Text("설정 > 모니터링에서 언제든 바꿀 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            guard !selectionReady else { return }
            selectionReady = true
            selection = installed
        }
    }
}
