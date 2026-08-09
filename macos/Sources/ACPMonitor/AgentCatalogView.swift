import SwiftUI

struct AgentCatalogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""

    private var filteredAgents: [ACPAgentCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.agentCatalog }
        return model.agentCatalog.filter {
            $0.name.lowercased().contains(query)
                || $0.registryId.lowercased().contains(query)
                || $0.description.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ACPLogoLockup(subtitle: "공식 ACP Agent 연결")
                Spacer()
                TextField("Agent 검색", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                Button("새로고침", systemImage: "arrow.clockwise") {
                    Task { await model.loadAgentCatalog(refresh: true) }
                }
                .disabled(model.agentCatalogLoading || model.agentCatalogMutationId != nil)
            }
            .padding(14)
            Divider()

            if model.agentCatalogLoading && model.agentCatalog.isEmpty {
                Spacer()
                ProgressView("ACP 공식 registry를 불러오는 중…")
                Spacer()
            } else {
                List(filteredAgents) { agent in
                    AgentCatalogRow(agent: agent)
                        .environmentObject(model)
                }
                .listStyle(.inset)
            }

            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Registry \(model.agentCatalogSource)\(model.agentCatalogStale ? " · 오래된 cache" : "")", systemImage: "shippingbox")
                    Spacer()
                    Text("\(model.agentCatalog.count)개 Agent")
                }
                .font(.caption)
                .foregroundStyle(model.agentCatalogStale ? .orange : .secondary)
                if let error = model.agentCatalogError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                Text("Off는 새 ACP 세션에서만 해당 Agent 사용을 막습니다. 이미 실행 중인 세션을 종료하거나 설치 파일을 삭제하지 않습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .task {
            if model.agentCatalog.isEmpty { await model.loadAgentCatalog() }
        }
    }
}

private struct AgentCatalogRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let agent: ACPAgentCatalogItem

    private var busy: Bool { model.agentCatalogMutationId == agent.registryId }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AgentCatalogIcon(agent: agent)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(agent.name).font(.callout.weight(.semibold))
                    Text(agent.version).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Text(agent.distribution.uppercased())
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(agent.description.isEmpty ? agent.registryId : agent.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !agent.installed {
                    Text(agent.installHint).font(.caption2).foregroundStyle(agent.installSupported ? Color.secondary : Color.orange)
                }
            }
            Spacer(minLength: 16)
            if busy {
                ProgressView().controlSize(.small)
                    .frame(width: 76)
            } else if agent.installed {
                Toggle(agent.enabled ? "On" : "Off", isOn: Binding(
                    get: { agent.enabled },
                    set: { enabled in Task { await model.setAgentEnabled(agent, enabled: enabled) } }
                ))
                .toggleStyle(.switch)
                .frame(width: 76)
            } else if agent.installSupported {
                Button("Install") { Task { await model.installAgent(agent) } }
                    .buttonStyle(.borderedProminent)
                    .frame(width: 76)
            } else if let website = agent.website {
                Button("설치 안내") { openURL(website) }
                    .frame(width: 76)
            } else {
                Text("지원 안 함").font(.caption).foregroundStyle(.tertiary).frame(width: 76)
            }
        }
        .padding(.vertical, 7)
        .opacity(model.agentCatalogMutationId == nil || busy ? 1 : 0.55)
        .disabled(model.agentCatalogMutationId != nil && !busy)
        .contextMenu {
            if let website = agent.website {
                Button("공식 페이지 열기") { openURL(website) }
            }
            Text(agent.registryId)
        }
    }
}

private struct AgentCatalogIcon: View {
    let agent: ACPAgentCatalogItem

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.background.secondary)
            if let icon = agent.icon {
                AsyncImage(url: icon) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    fallback
                }
                .padding(7)
            } else {
                fallback
            }
        }
        .frame(width: 42, height: 42)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(agent.installed ? (agent.enabled ? Color.green : Color.secondary) : Color.orange)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.background, lineWidth: 2))
        }
    }

    private var fallback: some View {
        Text(String(agent.name.prefix(1)).uppercased())
            .font(.headline)
            .foregroundStyle(.secondary)
    }
}
