import Foundation

struct MonitorEndpoint: Sendable {
    let baseURL: URL
    let apiToken: String

    func request(path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

actor MonitorClient {
    typealias MessageHandler = @MainActor @Sendable (JSONValue) -> Void
    typealias StateHandler = @MainActor @Sendable (Bool, String?) -> Void

    private var streamTask: Task<Void, Never>?

    func fetchMeta(endpoint: MonitorEndpoint) async throws -> MonitorMeta {
        let (data, response) = try await URLSession.shared.data(for: endpoint.request(path: "api/meta"))
        try validate(response: response, data: data)
        return try MonitorMeta.decode(data)
    }

    func fetchInstalledFrontdoors(endpoint: MonitorEndpoint) async throws -> InstalledFrontdoors {
        let (data, response) = try await URLSession.shared.data(for: endpoint.request(path: "api/frontdoors"))
        try validate(response: response, data: data)
        return try InstalledFrontdoors.decode(data)
    }

    func fetchSnapshot(endpoint: MonitorEndpoint, ifRevision revision: Int? = nil) async throws -> MonitorSnapshot? {
        var request = endpoint.request(path: "api/snapshot")
        if let revision { request.setValue("\"monitor-\(revision)\"", forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 304 { return nil }
        try validate(response: response, data: data)
        return try MonitorSnapshot.decode(data)
    }

    func fetchAgentCatalog(endpoint: MonitorEndpoint, refresh: Bool = false) async throws -> ACPAgentCatalogSnapshot {
        var components = URLComponents(url: endpoint.baseURL.appendingPathComponent("api/agents"), resolvingAgainstBaseURL: false)!
        if refresh { components.queryItems = [URLQueryItem(name: "refresh", value: "1")] }
        var request = endpoint.request(path: "api/agents")
        request.url = components.url
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try ACPAgentCatalogSnapshot.decode(data)
    }

    func mutateAgentCatalog(
        endpoint: MonitorEndpoint,
        body: [String: JSONValue]
    ) async throws -> ACPAgentCatalogSnapshot {
        var request = endpoint.request(path: "api/agents", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues(\.foundationValue))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try ACPAgentCatalogSnapshot.decode(data)
    }

    func fetchSkillStatus(endpoint: MonitorEndpoint) async throws -> DelegatorSkillStatus {
        let (data, response) = try await URLSession.shared.data(for: endpoint.request(path: "api/skill"))
        try validate(response: response, data: data)
        return try DelegatorSkillStatus.decode(data)
    }

    /// `install` adds the skill where it is missing; `force` replaces copies
    /// the user edited.
    func syncSkill(endpoint: MonitorEndpoint, install: [String], force: [String]) async throws -> DelegatorSkillStatus {
        var request = endpoint.request(path: "api/skill", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["install": install, "force": force] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try DelegatorSkillStatus.decode(data)
    }

    func fetchHookStatus(endpoint: MonitorEndpoint) async throws -> MonitoringHookStatus {
        let (data, response) = try await URLSession.shared.data(for: endpoint.request(path: "api/hooks"))
        try validate(response: response, data: data)
        return try MonitoringHookStatus.decode(data)
    }

    /// `action` is "install" or "uninstall"; `providers` limits it to some CLIs.
    /// `consent` records the user's agreement with an install; `decline`
    /// records a "no" so the app does not ask again until the scope changes.
    func mutateHooks(
        endpoint: MonitorEndpoint,
        action: String,
        providers: [String],
        consent: Bool = false,
        decline: Bool = false
    ) async throws -> MonitoringHookStatus {
        var request = endpoint.request(path: "api/hooks", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": action, "providers": providers, "consent": consent, "decline": decline
        ] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try MonitoringHookStatus.decode(data)
    }

    /// One page of a session's events older than sequence `before` (all of
    /// its newest when nil), oldest first.
    func fetchSessionEvents(
        endpoint: MonitorEndpoint,
        sessionId: String,
        before: Int?,
        limit: Int = 200
    ) async throws -> SessionEventsPage {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encodedId = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) ?? sessionId
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = "\(basePath)/api/sessions/\(encodedId)/events"
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { items.append(URLQueryItem(name: "before", value: String(before))) }
        components.queryItems = items
        var request = endpoint.request(path: "api/sessions")
        request.url = components.url
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try SessionEventsPage.decode(data, sessionId: sessionId)
    }

    /// Persisted session records updated before `before` (an ISO timestamp),
    /// newest first.
    /// `beforeId` breaks ties between sessions with the same `updatedAt`.
    func fetchHistory(endpoint: MonitorEndpoint, before: String?, beforeId: String? = nil, limit: Int = 50) async throws -> MonitorHistoryPage {
        var components = URLComponents(url: endpoint.baseURL.appendingPathComponent("api/history"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { items.append(URLQueryItem(name: "before", value: before)) }
        if let beforeId { items.append(URLQueryItem(name: "beforeId", value: beforeId)) }
        components.queryItems = items
        var request = endpoint.request(path: "api/history")
        request.url = components.url
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try MonitorHistoryPage.decode(data)
    }

    func fetchHistoryStats(endpoint: MonitorEndpoint) async throws -> MonitorHistoryStats {
        let (data, response) = try await URLSession.shared.data(for: endpoint.request(path: "api/history/stats"))
        try validate(response: response, data: data)
        return try MonitorHistoryStats.decode(data)
    }

    /// Deletes all history except live sessions; returns the new stats.
    func clearHistory(endpoint: MonitorEndpoint) async throws -> MonitorHistoryStats {
        var request = endpoint.request(path: "api/history", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "clear"])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try MonitorHistoryStats.decode(data)
    }

    func fetchGatewayConfig(endpoint: MonitorEndpoint) async throws -> GatewayConfigSnapshot {
        let (data, response) = try await URLSession.shared.data(for: endpoint.request(path: "api/gateway-config"))
        try validate(response: response, data: data)
        return try GatewayConfigSnapshot.decode(data)
    }

    func saveGatewayConfig(endpoint: MonitorEndpoint, values: [String: JSONValue]) async throws -> GatewayConfigSnapshot {
        var request = endpoint.request(path: "api/gateway-config", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": "set",
            "values": values.mapValues(\.foundationValue)
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try GatewayConfigSnapshot.decode(data)
    }

    func retentionPreview(
        endpoint: MonitorEndpoint,
        sessionRetentionMs: Int?,
        artifactSessionLimit: Int?
    ) async throws -> RetentionPreview {
        var request = endpoint.request(path: "api/retention-preview", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let sessionRetentionMs { body["sessionRetentionMs"] = sessionRetentionMs }
        if let artifactSessionLimit { body["artifactSessionLimit"] = artifactSessionLimit }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try RetentionPreview.decode(data)
    }

    func resetGatewayConfig(endpoint: MonitorEndpoint, ids: [String]) async throws -> GatewayConfigSnapshot {
        var request = endpoint.request(path: "api/gateway-config", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "reset", "ids": ids])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try GatewayConfigSnapshot.decode(data)
    }

    func fetchSessionConfig(endpoint: MonitorEndpoint, sessionId: String) async throws -> SessionConfigSnapshot {
        var components = URLComponents(url: endpoint.baseURL.appendingPathComponent("api/session-config"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]
        var request = endpoint.request(path: "api/session-config")
        request.url = components.url
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let snapshot = try SessionConfigSnapshot.decode(data)
        guard snapshot.sessionId == sessionId else { throw MonitorDecodeError.invalidMessage }
        return snapshot
    }

    func setSessionConfig(endpoint: MonitorEndpoint, sessionId: String, configId: String, value: JSONValue) async throws -> SessionConfigSnapshot {
        var request = endpoint.request(path: "api/session-config", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionId,
            "configId": configId,
            "value": value.foundationValue
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let snapshot = try SessionConfigSnapshot.decode(data)
        guard snapshot.sessionId == sessionId else { throw MonitorDecodeError.invalidMessage }
        return snapshot
    }

    func restartGateway(endpoint: MonitorEndpoint) async throws {
        let request = endpoint.request(path: "api/gateway-restart", method: "POST")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    /// Notch chat calls (`api/chat/open|prompt|permission|cancel`): the
    /// sidecar forwards the body to the Gateway and returns its answer as is.
    func chatPost(endpoint: MonitorEndpoint, path: String, body: [String: JSONValue]) async throws -> JSONValue {
        try await postJSON(endpoint: endpoint, path: "api/chat/\(path)", body: body)
    }

    func postJSON(endpoint: MonitorEndpoint, path: String, body: [String: JSONValue]) async throws -> JSONValue {
        var request = endpoint.request(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 150
        request.httpBody = try JSONSerialization.data(withJSONObject: body.mapValues(\.foundationValue))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return JSONValue(any: try JSONSerialization.jsonObject(with: data))
    }

    func chatPoll(endpoint: MonitorEndpoint, sessionId: String, cursor: Int, waitMs: Int) async throws -> JSONValue {
        var components = URLComponents(url: endpoint.baseURL.appendingPathComponent("api/chat/poll"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "waitMs", value: String(waitMs))
        ]
        var request = endpoint.request(path: "api/chat/poll")
        request.url = components.url
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return JSONValue(any: try JSONSerialization.jsonObject(with: data))
    }

    func startStream(endpoint: MonitorEndpoint, onMessage: @escaping MessageHandler, onState: @escaping StateHandler) {
        streamTask?.cancel()
        streamTask = Task {
            var retryDelay: UInt64 = 500_000_000
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: endpoint.request(path: "api/stream"))
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    await onState(true, nil)
                    retryDelay = 500_000_000
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: "),
                              let data = String(line.dropFirst(6)).data(using: .utf8) else { continue }
                        let value = try decodeJSONValue(data)
                        guard let object = value.objectValue else { throw MonitorDecodeError.invalidMessage }
                        try MonitorCompatibility.validate(object)
                        await onMessage(value)
                    }
                    throw URLError(.networkConnectionLost)
                } catch is CancellationError {
                    return
                } catch {
                    await onState(false, error.localizedDescription)
                    try? await Task.sleep(nanoseconds: retryDelay)
                    retryDelay = min(retryDelay * 2, 8_000_000_000)
                }
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw MonitorClientError.decode(data: data, statusCode: http.statusCode)
        }
    }
}
