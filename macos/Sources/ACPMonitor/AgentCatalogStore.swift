import Combine
import Foundation

@MainActor
final class AgentCatalogStore: ObservableObject {
    @Published private(set) var agents: [ACPAgentCatalogItem] = []
    @Published private(set) var loading = false
    @Published private(set) var mutationId: String?
    @Published private(set) var source = "—"
    @Published private(set) var stale = false
    @Published private(set) var error: String?

    func load(client: MonitorClient, endpoint: MonitorEndpoint, refresh: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            apply(try await client.fetchAgentCatalog(endpoint: endpoint, refresh: refresh))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func mutate(
        client: MonitorClient,
        endpoint: MonitorEndpoint,
        agent: ACPAgentCatalogItem,
        body: [String: JSONValue]
    ) async {
        guard mutationId == nil else { return }
        mutationId = agent.id
        error = nil
        defer { mutationId = nil }
        do {
            apply(try await client.mutateAgentCatalog(endpoint: endpoint, body: body))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setConnectionUnavailable() {
        error = "Gateway monitor가 아직 연결되지 않았습니다."
    }

    private func apply(_ snapshot: ACPAgentCatalogSnapshot) {
        agents = snapshot.agents
        source = snapshot.source
        stale = snapshot.stale
        error = snapshot.warning
    }
}
