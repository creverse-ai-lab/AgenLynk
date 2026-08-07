import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let defaultPetProjectPath = "/Users/cyyoon/dev/personal_program/agent-status-pet"

    private enum Key {
        static let activeOnly = "monitor.activeOnly"
        static let showThoughts = "monitor.showThoughts"
        static let showToolEvents = "monitor.showToolEvents"
        static let graphWindowMinutes = "monitor.graphWindowMinutes"
        static let followLatestEvent = "monitor.followLatestEvent"
        static let nodePath = "monitor.nodePath"
        static let petEnabled = "monitor.petEnabled"
        static let petProjectPath = "monitor.petProjectPath"
    }

    private let defaults: UserDefaults

    @Published var activeOnly: Bool { didSet { defaults.set(activeOnly, forKey: Key.activeOnly) } }
    @Published var showThoughts: Bool { didSet { defaults.set(showThoughts, forKey: Key.showThoughts) } }
    @Published var showToolEvents: Bool { didSet { defaults.set(showToolEvents, forKey: Key.showToolEvents) } }
    @Published var graphWindowMinutes: Int { didSet { defaults.set(graphWindowMinutes, forKey: Key.graphWindowMinutes) } }
    @Published var followLatestEvent: Bool { didSet { defaults.set(followLatestEvent, forKey: Key.followLatestEvent) } }
    @Published var nodePath: String { didSet { defaults.set(nodePath, forKey: Key.nodePath) } }
    @Published var petEnabled: Bool { didSet { defaults.set(petEnabled, forKey: Key.petEnabled) } }
    @Published var petProjectPath: String { didSet { defaults.set(petProjectPath, forKey: Key.petProjectPath) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeOnly = defaults.object(forKey: Key.activeOnly) as? Bool ?? false
        showThoughts = defaults.object(forKey: Key.showThoughts) as? Bool ?? true
        showToolEvents = defaults.object(forKey: Key.showToolEvents) as? Bool ?? true
        graphWindowMinutes = defaults.object(forKey: Key.graphWindowMinutes) as? Int ?? 15
        followLatestEvent = defaults.object(forKey: Key.followLatestEvent) as? Bool ?? true
        nodePath = defaults.string(forKey: Key.nodePath) ?? ""
        petEnabled = defaults.object(forKey: Key.petEnabled) as? Bool ?? false
        petProjectPath = defaults.string(forKey: Key.petProjectPath) ?? Self.defaultPetProjectPath
    }

    func reset() {
        activeOnly = false
        showThoughts = true
        showToolEvents = true
        graphWindowMinutes = 15
        followLatestEvent = true
        nodePath = ""
    }
}
