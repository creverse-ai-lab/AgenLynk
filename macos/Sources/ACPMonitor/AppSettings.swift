import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let activeOnly = "monitor.activeOnly"
        static let showThoughts = "monitor.showThoughts"
        static let showToolEvents = "monitor.showToolEvents"
        static let graphWindowMinutes = "monitor.graphWindowMinutes"
        static let monitorViewMode = "monitor.viewMode"
        static let followLatestEvent = "monitor.followLatestEvent"
        static let followLatestEventUXMigration = "monitor.followLatestEventUXMigrationV2"
        static let nodePath = "monitor.nodePath"
        static let petEnabled = "monitor.petEnabled"
        static let petExecutablePath = "monitor.petExecutablePath"
        static let petWatcherProjectPath = "monitor.petWatcherProjectPath"
    }

    private let defaults: UserDefaults

    @Published var activeOnly: Bool { didSet { defaults.set(activeOnly, forKey: Key.activeOnly) } }
    @Published var showThoughts: Bool { didSet { defaults.set(showThoughts, forKey: Key.showThoughts) } }
    @Published var showToolEvents: Bool { didSet { defaults.set(showToolEvents, forKey: Key.showToolEvents) } }
    @Published var graphWindowMinutes: Int { didSet { defaults.set(graphWindowMinutes, forKey: Key.graphWindowMinutes) } }
    @Published var monitorViewMode: String { didSet { defaults.set(monitorViewMode, forKey: Key.monitorViewMode) } }
    @Published var followLatestEvent: Bool { didSet { defaults.set(followLatestEvent, forKey: Key.followLatestEvent) } }
    @Published var nodePath: String { didSet { defaults.set(nodePath, forKey: Key.nodePath) } }
    @Published var petEnabled: Bool { didSet { defaults.set(petEnabled, forKey: Key.petEnabled) } }
    /// Explicit path to the Pet/user-renderer executable. No default: a
    /// developer-specific project path must never ship as a launch default.
    @Published var petExecutablePath: String { didSet { defaults.set(petExecutablePath, forKey: Key.petExecutablePath) } }
    /// Optional project directory used only to detect a local
    /// `codex_app_watcher.py`, unrelated to the Pet renderer contract.
    @Published var petWatcherProjectPath: String { didSet { defaults.set(petWatcherProjectPath, forKey: Key.petWatcherProjectPath) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeOnly = defaults.object(forKey: Key.activeOnly) as? Bool ?? false
        showThoughts = defaults.object(forKey: Key.showThoughts) as? Bool ?? true
        showToolEvents = defaults.object(forKey: Key.showToolEvents) as? Bool ?? true
        graphWindowMinutes = defaults.object(forKey: Key.graphWindowMinutes) as? Int ?? 15
        monitorViewMode = defaults.string(forKey: Key.monitorViewMode) ?? "branch"
        if defaults.bool(forKey: Key.followLatestEventUXMigration) {
            followLatestEvent = defaults.object(forKey: Key.followLatestEvent) as? Bool ?? false
        } else {
            // V2 stops stealing the user's selection. Following is now an explicit
            // control at the top of the sequence and starts disabled once.
            followLatestEvent = false
            defaults.set(false, forKey: Key.followLatestEvent)
            defaults.set(true, forKey: Key.followLatestEventUXMigration)
        }
        nodePath = defaults.string(forKey: Key.nodePath) ?? ""
        petEnabled = defaults.object(forKey: Key.petEnabled) as? Bool ?? false
        petExecutablePath = defaults.string(forKey: Key.petExecutablePath) ?? ""
        petWatcherProjectPath = defaults.string(forKey: Key.petWatcherProjectPath) ?? ""
    }

    func reset() {
        activeOnly = false
        showThoughts = true
        showToolEvents = true
        graphWindowMinutes = 15
        monitorViewMode = "branch"
        followLatestEvent = false
        nodePath = ""
        petEnabled = false
        petExecutablePath = ""
        petWatcherProjectPath = ""
    }
}
