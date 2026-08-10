import SwiftUI

// First-run installation surface shown when ~/.acp-gateway/install.json is
// missing or invalid. Lets the user pick a Frontdoor and invokes the bundled
// bootstrap (--install-all --front-door <target> --refresh-registry) through
// AppModel; the dashboard only starts after a successful health-verified
// install (see AppModel.startOnboardingInstall / completeOnboarding).
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ACPLogoMark().frame(width: 40, height: 40)
            Text("Lynk 처음 설치").font(.title2.weight(.semibold))
            Text("이 Mac에 ACP Gateway를 설치합니다. 대화할 Frontdoor를 선택한 뒤 설치를 시작하세요.")
                .foregroundStyle(.secondary)

            Picker("Frontdoor", selection: $model.onboardingFrontDoor) {
                Text("Codex").tag("codex")
                Text("Claude").tag("claude")
                Text("Grok").tag("grok")
            }
            .pickerStyle(.segmented)
            .disabled(model.onboardingRunning)
            .frame(maxWidth: 320)

            if !model.onboardingInstallLocationReady {
                Label("Lynk를 Applications 폴더로 옮긴 뒤 다시 실행해야 설치 경로가 유지됩니다.", systemImage: "externaldrive.badge.exclamationmark")
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
            .disabled(model.onboardingRunning || !model.onboardingInstallLocationReady)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
    }
}
