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

    func fetchSnapshot(endpoint: MonitorEndpoint) async throws -> MonitorSnapshot {
        let (data, response) = try await URLSession.shared.data(for: endpoint.request(path: "api/snapshot"))
        try validate(response: response, data: data)
        return try MonitorSnapshot.decode(data)
    }

    func fetchSessionConfig(endpoint: MonitorEndpoint, sessionId: String) async throws -> SessionConfigResponse {
        var components = URLComponents(url: endpoint.baseURL.appendingPathComponent("api/session-config"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(endpoint.apiToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try SessionConfigResponse.decode(data)
    }

    func setSessionConfig(
        endpoint: MonitorEndpoint,
        sessionId: String,
        configId: String,
        value: JSONValue
    ) async throws -> SessionConfigResponse {
        var request = endpoint.request(path: "api/session-config", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionId,
            "configId": configId,
            "value": value.foundationValue
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try SessionConfigResponse.decode(data)
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

    func resetGatewayConfig(endpoint: MonitorEndpoint, ids: [String]) async throws -> GatewayConfigSnapshot {
        var request = endpoint.request(path: "api/gateway-config", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "reset", "ids": ids])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try GatewayConfigSnapshot.decode(data)
    }

    func restartGateway(endpoint: MonitorEndpoint) async throws {
        let request = endpoint.request(path: "api/gateway-restart", method: "POST")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
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
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw MonitorClientError.server(message ?? "Monitor request failed (HTTP \(http.statusCode))")
        }
    }
}

enum MonitorClientError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        guard case let .server(message) = self else { return nil }
        return message
    }
}
