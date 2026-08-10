import SwiftUI

/// Versions, install location, and the Gateway runtime updater in one place.
///
/// The buttons drive the same `runtime-updater.js` operations as
/// `runtime-updater-cli.js` and show that library's own error codes, so the CLI
/// and the app can never disagree about what happened. Without this screen an
/// already-installed runtime is never replaced — `ensureRuntimeInstalled`
/// deliberately refuses to overwrite a valid one — so a Lynk update would
/// otherwise ship code that no existing install ever receives.
struct RuntimeUpdateView: View {
    @EnvironmentObject private var model: AppModel

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (build \(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ACPLogoLockup(subtitle: "버전과 Gateway runtime 업데이트")
                Spacer()
                Button("새로고침", systemImage: "arrow.clockwise") {
                    Task { await model.loadRuntimeInspection() }
                }
                .disabled(model.runtimeLoading || model.runtimeBusy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let warning = runtimeSplitWarning(gateway: model.gateway) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    versionSection
                    installedSection
                    if let notice = model.runtimeNotice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                    }
                    if let error = model.runtimeError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            Divider()
            actionBar
        }
        .task { await model.loadRuntimeInspection() }
    }

    private var versionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Lynk", value: appVersion)
                LabeledContent("Gateway", value: "\(model.gatewayVersion) · build \(model.gatewayBuild)")
                LabeledContent("Monitor API", value: model.monitorApiVersionText)
                LabeledContent("Node", value: model.runtimeInspection?.current?.nodeVersion ?? "—")
                LabeledContent("설치 위치", value: model.runtimeInspection?.runtimeRoot ?? "—")
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("버전", systemImage: "number").font(.headline)
        }
    }

    private var installedSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if model.runtimeLoading && model.runtimeInspection == nil {
                    ProgressView("설치된 runtime을 확인하는 중…")
                } else if let versions = model.runtimeInspection?.versions, !versions.isEmpty {
                    ForEach(versions.sorted { $0.versionId > $1.versionId }) { version in
                        RuntimeVersionRow(version: version)
                    }
                } else {
                    Text("설치된 runtime이 없습니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("설치된 runtime", systemImage: "shippingbox").font(.headline)
        }
    }

    private var actionBar: some View {
        HStack {
            // Rollback only exists once an activation recorded a previous
            // known-good target.
            Button("이전 버전으로 롤백") { Task { await model.rollbackRuntime() } }
                .disabled(model.runtimeBusy || !(model.runtimeInspection?.canRollback ?? false))
            Spacer()
            if model.runtimeBusy { ProgressView().controlSize(.small) }
            Button("이 앱의 runtime 설치 및 적용") { Task { await model.updateRuntimeFromAppSeed() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.runtimeBusy)
                .help("앱에 포함된 Gateway runtime을 설치하고 current로 전환합니다. 진행 중인 작업이 있으면 보류됩니다.")
        }
        .padding(14)
    }
}

private struct RuntimeVersionRow: View {
    let version: RuntimeVersionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: version.isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(version.isCurrent ? .green : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(version.versionId).font(.callout.weight(.medium)).textSelection(.enabled)
                    if version.isCurrent { badge("현재", .green) }
                    if version.isPrevious { badge("이전", .blue) }
                    if version.apiCompatible == false { badge("API 비호환", .orange) }
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                if let manifestError = version.manifestError {
                    Text(manifestError).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        var parts: [String] = []
        if let api = version.gatewayApiVersion { parts.append("API v\(api)") }
        if let node = version.nodeVersion { parts.append("Node \(node)") }
        parts.append(version.runtimeRoot)
        return parts.joined(separator: " · ")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}
