import SwiftUI

/// Versions, install location, and the Gateway runtime updater in one place.
///
/// The buttons drive the same `runtime-updater.js` operations as
/// `runtime-updater-cli.js` and show that library's own error codes, so the CLI
/// and the app can never disagree about what happened. Without this screen an
/// already-installed runtime is never replaced — `ensureRuntimeInstalled`
/// deliberately refuses to overwrite a valid one — so an AgenLynk update would
/// otherwise ship code that no existing install ever receives.
struct RuntimeUpdateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var pendingSwitch: RuntimeSwitch?
    @State private var pendingPrune: RuntimePrunePlan?

    /// A runtime change waiting for the user's confirmation.
    private struct RuntimeSwitch: Identifiable {
        enum Kind { case installSeed, rollback }
        let id = UUID()
        let kind: Kind
        let from: String
        let to: String
    }

    private static func versionText(_ version: String?, _ build: String?) -> String {
        switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): build
        default: "알 수 없는 버전"
        }
    }

    private var currentRuntimeText: String {
        let current = model.runtimeInspection?.current
        return Self.versionText(current?.gatewayVersion, current?.gatewayBuildId)
    }

    private func confirmInstallSeed() {
        let seed = model.seedGatewayVersion
        pendingSwitch = RuntimeSwitch(
            kind: .installSeed,
            from: currentRuntimeText,
            to: Self.versionText(seed?.gatewayVersion, seed?.gatewayBuildId)
        )
    }

    private func confirmRollback() {
        let previous = model.runtimeInspection?.versions.first(where: \.isPrevious)
        pendingSwitch = RuntimeSwitch(
            kind: .rollback,
            from: currentRuntimeText,
            to: Self.versionText(previous?.gatewayVersion, previous?.gatewayBuildId)
        )
    }

    private var switchPresented: Binding<Bool> {
        Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } })
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (build \(build))"
    }

    /// Re-checks all three update sources (app release feed, installed runtime,
    /// adapter catalog) that the top "업데이트" section compares.
    private func refreshAll() async {
        async let app: Void = model.checkAppUpdate()
        async let runtime: Void = model.loadRuntimeInspection()
        async let catalog: Void = model.loadAgentCatalog()
        _ = await (app, runtime, catalog)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ACPLogoLockup(subtitle: "버전과 Gateway 런타임 업데이트")
                Spacer()
                Button("새로고침", systemImage: "arrow.clockwise") {
                    Task { await refreshAll() }
                }
                .disabled(model.runtimeLoading || model.runtimeBusy || model.appUpdateChecking)
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
                    updateSection
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
        .task { await refreshAll() }
        .alert("옛 런타임 정리", isPresented: Binding(get: { pendingPrune != nil }, set: { if !$0 { pendingPrune = nil } }), presenting: pendingPrune) { _ in
            Button("취소", role: .cancel) { pendingPrune = nil }
            Button("삭제", role: .destructive) {
                pendingPrune = nil
                Task { await model.pruneRuntimeVersions() }
            }
        } message: { plan in
            Text("\(plan.removed.map(\.versionId).joined(separator: ", "))을 삭제해 \(plan.freedText)를 확보합니다. 삭제한 버전으로는 되돌릴 수 없습니다.")
        }
        .alert("Gateway 런타임 전환", isPresented: switchPresented, presenting: pendingSwitch) { change in
            Button("취소", role: .cancel) { pendingSwitch = nil }
            Button(change.kind == .rollback ? "이전 버전으로 전환" : "설치 및 전환") {
                pendingSwitch = nil
                Task {
                    switch change.kind {
                    case .installSeed: await model.updateRuntimeFromAppSeed()
                    case .rollback: await model.rollbackRuntime()
                    }
                }
            }
        } message: { change in
            if change.kind == .rollback {
                Text("이전 런타임으로 되돌리면 이 버전에 고정되어, 앱을 업데이트해도 런타임은 바뀌지 않습니다. 진행 중 작업이 있으면 끝난 뒤 전환되고, Gateway를 다시 시작해야 적용됩니다.")
            } else {
                Text("Gateway 런타임을 \(change.from)에서 \(change.to)로 전환할까요? 진행 중 작업이 있으면 완료될 때까지 적용되지 않습니다.")
            }
        }
    }

    /// The unified "업데이트" surface: app, Gateway runtime, and ACP adapters,
    /// each comparing 현재 vs 최신 with an action only when they differ.
    private var updateSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                appUpdateRow
                Divider()
                gatewayUpdateRow
                Divider()
                adapterUpdateRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("업데이트", systemImage: "arrow.down.circle").font(.headline)
        }
    }

    private var appUpdateRow: some View {
        UpdateRow(
            title: "AgenLynk 앱",
            current: model.localAppVersion,
            latest: model.latestAppRelease?.version,
            checking: model.appUpdateChecking,
            failure: model.appUpdateError
        ) {
            if model.appUpdateAvailable, let release = model.latestAppRelease {
                VStack(alignment: .trailing, spacing: 3) {
                    Button("다운로드") { openURL(release.downloadURL) }
                        .buttonStyle(.borderedProminent)
                    Text("새 DMG를 받아 Applications의 앱을 교체하세요")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if model.appUpdateError == nil && !model.appUpdateChecking {
                Text("최신").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var gatewayUpdateRow: some View {
        UpdateRow(
            title: "Gateway 런타임",
            current: model.runtimeInspection?.current.map { "\($0.gatewayVersion ?? "—") · \($0.gatewayBuildId ?? "—")" } ?? "—",
            latest: model.seedGatewayVersion.map { "\($0.gatewayVersion) · \($0.gatewayBuildId)" },
            checking: model.runtimeLoading && model.runtimeInspection == nil,
            failure: model.seedGatewayVersion == nil ? "이 빌드에는 포함된 런타임이 없습니다" : nil
        ) {
            if model.gatewayUpdateAvailable {
                Button("이 앱의 런타임 설치 및 적용") { confirmInstallSeed() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runtimeBusy)
            } else if model.seedGatewayVersion != nil {
                Text("최신").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var adapterUpdateRow: some View {
        UpdateRow(
            title: "ACP 어댑터",
            current: model.agentCatalog.isEmpty ? "—" : "설치된 어댑터 \(model.agentCatalog.filter(\.installed).count)개",
            latest: nil,
            checking: model.agentCatalogLoading && model.agentCatalog.isEmpty,
            failure: nil
        ) {
            if model.adapterUpdateCount > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(model.adapterUpdateCount)개 업데이트 가능")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    Text("ACP 연결 탭에서 업데이트")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if !model.agentCatalog.isEmpty {
                Text("최신").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var versionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("AgenLynk", value: appVersion)
                LabeledContent("Gateway", value: "\(model.gatewayVersion) · build \(model.gatewayBuild)")
                LabeledContent("Sidecar", value: model.sidecarVersionText)
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
                if let notice = model.runtimeInspection?.pinnedNotice {
                    Label(notice, systemImage: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.runtimeLoading && model.runtimeInspection == nil {
                    ProgressView("설치된 런타임을 확인하는 중…")
                } else if let versions = model.runtimeInspection?.versions, !versions.isEmpty {
                    ForEach(versions.sorted { $0.versionId > $1.versionId }) { version in
                        RuntimeVersionRow(version: version)
                    }
                } else {
                    Text("설치된 런타임이 없습니다.").font(.caption).foregroundStyle(.secondary)
                }
                if let plan = model.runtimePrunePreview, !plan.removed.isEmpty || !plan.inUse.isEmpty {
                    Divider()
                    pruneRow(plan)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("설치된 런타임", systemImage: "shippingbox").font(.headline)
        }
    }

    /// Old versions pile up with every update (each holds its own Node and
    /// Gateway); current and the rollback target always stay.
    private func pruneRow(_ plan: RuntimePrunePlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if plan.removed.isEmpty {
                    Text("정리할 수 있는 옛 런타임이 없습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("옛 런타임 \(plan.removed.count)개 (\(plan.removed.map(\.versionId).joined(separator: ", "))) · \(plan.freedText) 확보 가능")
                        .font(.caption)
                }
                Spacer()
                Button("옛 런타임 정리") { pendingPrune = plan }
                    .disabled(plan.removed.isEmpty || model.runtimeBusy)
            }
            ForEach(plan.inUse) { item in
                Text("\(item.versionId)은 아직 사용 중이라 남겨 둡니다 (\(item.reasonText)).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("현재 버전과 되돌리기용 이전 버전은 항상 남습니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        HStack {
            // Rollback only exists once an activation recorded a previous
            // known-good target.
            let canRollback = model.runtimeInspection?.canRollback ?? false
            Button("이전 버전으로 롤백") { confirmRollback() }
                .disabled(model.runtimeBusy || !canRollback)
                .optionalHelp(canRollback ? nil : "바로 전에 쓰던 런타임이 있을 때만 되돌릴 수 있습니다.")
            Spacer()
            if model.runtimeBusy { ProgressView().controlSize(.small) }
            // Already on the app's own runtime: nothing to install.
            Button("이 앱의 런타임 설치 및 적용") { confirmInstallSeed() }
                .buttonStyle(.borderedProminent)
                .disabled(model.runtimeBusy || !model.gatewayUpdateAvailable)
                .help("이 앱에 포함된 런타임을 설치하면 고정이 풀립니다.")
        }
        .padding(14)
    }
}

/// One row of the "업데이트" surface: a component name, its 현재/최신 versions,
/// and a trailing action supplied by the caller (download, apply, or a "최신"
/// badge). A check in progress shows a spinner; a non-fatal failure is shown
/// as caption text rather than blocking the row.
private struct UpdateRow<Trailing: View>: View {
    let title: String
    let current: String
    let latest: String?
    let checking: Bool
    let failure: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    Text("현재 \(current)").font(.caption).foregroundStyle(.secondary)
                    if let latest {
                        Text("→ 최신 \(latest)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                if let failure {
                    Text(failure).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            if checking {
                ProgressView().controlSize(.small)
            } else {
                trailing()
            }
        }
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
