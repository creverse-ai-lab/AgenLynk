import Foundation

enum AppUpdateServiceError: LocalizedError {
    case requestFailed
    case invalidResponse

    var errorDescription: String? { "확인 실패" }
}

/// Owns all network access for the app-release feed. `AppModel` receives a
/// decoded value and never touches `URLSession` directly.
actor AppUpdateService {
    private let session: URLSession
    private let releasesURL: URL

    init(
        session: URLSession = .shared,
        releasesURL: URL = URL(string: "https://api.github.com/repos/creverse-ai-lab/agenlynk/releases")!
    ) {
        self.session = session
        self.releasesURL = releasesURL
    }

    func latestRelease() async throws -> AppReleaseInfo {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppUpdateServiceError.requestFailed
        }
        guard let release = parseGitHubReleases(data) else {
            throw AppUpdateServiceError.invalidResponse
        }
        return release
    }
}
