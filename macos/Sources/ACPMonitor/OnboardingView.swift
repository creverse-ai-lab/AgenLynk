import LynkArt
import SwiftUI

// First-run installation surface shown when ~/.acp-gateway/install.json is
// missing or invalid. Lets the user pick a Frontdoor and invokes the bundled
// bootstrap (--install-all --front-door <target> --refresh-registry) through
// AppModel; the dashboard only starts after a successful health-verified
// install (see AppModel.startOnboardingInstall / completeOnboarding).
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    /// CLIs installed on this Mac; only these can be picked for hooks.
    @State private var installedCLIs = MonitoringConsentChoices.installedCLIs()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ACPLogoMark().frame(width: 40, height: 40)
            Text("AgenLynk 처음 설치").font(.title2.weight(.semibold))
            Text("이 Mac에 ACP Gateway를 설치합니다. 대화할 Frontdoor를 하나 이상 선택한 뒤 설치를 시작하세요.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.frontdoorChoices, id: \.id) { choice in
                    Toggle(choice.label, isOn: Binding(
                        get: { model.onboardingFrontdoors.contains(choice.id) },
                        set: { isOn in
                            if isOn { model.onboardingFrontdoors.insert(choice.id) }
                            else { model.onboardingFrontdoors.remove(choice.id) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(model.onboardingRunning)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)

            Divider().frame(maxWidth: 520)

            // A separate, optional choice: it edits the CLIs' own config files,
            // so it must not read as part of the Gateway install above.
            VStack(alignment: .leading, spacing: 8) {
                Text("실시간 모니터링 (선택)").font(.headline)
                MonitoringConsentChoices(
                    selection: $model.onboardingMonitoringHooks,
                    installed: installedCLIs,
                    disabled: model.onboardingRunning
                )
                // Explicit opt-in: nothing is checked at first, and leaving it
                // that way records no answer (the app asks again later).
                Label(hooksChosen
                      ? "선택한 CLI의 설정 파일에 hook을 추가합니다."
                      : "hook 없이 계속합니다. 나중에 설정 > 모니터링에서 켤 수 있습니다.",
                      systemImage: hooksChosen ? "checkmark.circle" : "circle.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520, alignment: .leading)

            if !model.onboardingInstallLocationReady {
                Label("AgenLynk를 Applications 폴더로 옮긴 뒤 다시 실행해야 설치 경로가 유지됩니다.", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }

            if model.onboardingRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("설치 중… (Gateway 상태 확인까지 포함합니다)")
                }
                .foregroundStyle(.secondary)
            }

            if !model.onboardingOutput.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.onboardingOutput.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(maxWidth: 520, maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            }

            if let onboardingError = model.onboardingError {
                Text(onboardingError).foregroundStyle(.red).font(.callout)
            }

            Button(model.onboardingRunning ? "설치 중…" : (model.onboardingError == nil ? "설치 시작" : "다시 시도")) {
                model.startOnboardingInstall()
            }
            .disabled(model.onboardingRunning || !model.onboardingInstallLocationReady || model.onboardingFrontdoors.isEmpty)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(minWidth: 560, minHeight: 560, alignment: .topLeading)
    }

    private var hooksChosen: Bool {
        !model.onboardingMonitoringHooks.intersection(installedCLIs).isEmpty
    }

    private struct FrontdoorChoice { let id: String; let label: String }
    private static let frontdoorChoices = AppModel.frontdoorInstallOrder.map {
        FrontdoorChoice(id: $0, label: cliProductName($0))
    }
}
