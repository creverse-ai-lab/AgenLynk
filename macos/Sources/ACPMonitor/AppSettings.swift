import Combine
import Foundation

enum BundledPet {
    static func executablePath(bundle: Bundle = .main, fileManager: FileManager = .default) -> String? {
        let executable = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/LynkPet.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/LynkPet", isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executable.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        return executable.path
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let activeOnly = "monitor.activeOnly"
        static let showThoughts = "monitor.showThoughts"
        static let showToolEvents = "monitor.showToolEvents"
        static let graphWindowMinutes = "monitor.graphWindowMinutes"
        static let followLatestEvent = "monitor.followLatestEvent"
        static let followLatestEventUXMigration = "monitor.followLatestEventUXMigrationV2"
        static let nodePath = "monitor.nodePath"
        static let petEnabled = "monitor.petEnabled"
        static let petExecutablePath = "monitor.petExecutablePath"
        static let bundledPetDefaultMigration = "monitor.bundledPetDefaultV1"
    }

    private let defaults: UserDefaults
    private let bundledPetExecutablePath: String?

    @Published var activeOnly: Bool { didSet { defaults.set(activeOnly, forKey: Key.activeOnly) } }
    @Published var showThoughts: Bool { didSet { defaults.set(showThoughts, forKey: Key.showThoughts) } }
    @Published var showToolEvents: Bool { didSet { defaults.set(showToolEvents, forKey: Key.showToolEvents) } }
    @Published var graphWindowMinutes: Int { didSet { defaults.set(graphWindowMinutes, forKey: Key.graphWindowMinutes) } }
    @Published var followLatestEvent: Bool { didSet { defaults.set(followLatestEvent, forKey: Key.followLatestEvent) } }
    @Published var nodePath: String { didSet { defaults.set(nodePath, forKey: Key.nodePath) } }
    @Published var petEnabled: Bool { didSet { defaults.set(petEnabled, forKey: Key.petEnabled) } }
    /// Optional custom renderer executable. Empty selects Lynk's bundled Pet.
    @Published var petExecutablePath: String { didSet { defaults.set(petExecutablePath, forKey: Key.petExecutablePath) } }

    var resolvedPetExecutablePath: String {
        let custom = petExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? (bundledPetExecutablePath ?? "") : custom
    }

    var usesBundledPet: Bool {
        petExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && bundledPetExecutablePath != nil
    }

    var bundledPetAvailable: Bool { bundledPetExecutablePath != nil }

    init(defaults: UserDefaults = .standard, bundledPetExecutablePath: String? = BundledPet.executablePath()) {
        self.defaults = defaults
        self.bundledPetExecutablePath = bundledPetExecutablePath
        activeOnly = defaults.object(forKey: Key.activeOnly) as? Bool ?? false
        showThoughts = defaults.object(forKey: Key.showThoughts) as? Bool ?? true
        showToolEvents = defaults.object(forKey: Key.showToolEvents) as? Bool ?? true
        graphWindowMinutes = defaults.object(forKey: Key.graphWindowMinutes) as? Int ?? 15
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
        let storedPetExecutablePath = defaults.string(forKey: Key.petExecutablePath) ?? ""
        let hasCustomPet = !storedPetExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        petExecutablePath = hasCustomPet ? storedPetExecutablePath : ""
        let storedPetEnabled = defaults.object(forKey: Key.petEnabled) as? Bool
        if bundledPetExecutablePath != nil && !defaults.bool(forKey: Key.bundledPetDefaultMigration) {
            // First build that actually contains LynkPet: make it the default
            // when no custom renderer was configured. Later explicit Off
            // choices are preserved by the migration marker.
            petEnabled = hasCustomPet ? (storedPetEnabled ?? false) : true
            defaults.set(petEnabled, forKey: Key.petEnabled)
            defaults.set(true, forKey: Key.bundledPetDefaultMigration)
        } else {
            petEnabled = storedPetEnabled ?? (bundledPetExecutablePath != nil)
        }
        if petEnabled && resolvedPetExecutablePath.isEmpty {
            petEnabled = false
            defaults.set(false, forKey: Key.petEnabled)
        }
    }

    func reset() {
        activeOnly = false
        showThoughts = true
        showToolEvents = true
        graphWindowMinutes = 15
        followLatestEvent = false
        nodePath = ""
        petEnabled = bundledPetExecutablePath != nil
        petExecutablePath = ""
    }
}
