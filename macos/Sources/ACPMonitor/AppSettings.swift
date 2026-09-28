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

/// The dashboard's center views (docs/ux-policy.md §9). Declared here, not
/// with the views, so the settings checks compile without SwiftUI.
enum DashboardMode: String, CaseIterable, Identifiable, Sendable {
    case cards, graph, sequence

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cards: "현황"
        case .graph: "그래프"
        case .sequence: "시퀀스"
        }
    }

    var symbol: String {
        switch self {
        case .cards: "rectangle.grid.2x2"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .sequence: "timeline.selection"
        }
    }

    /// One line on what the view is for (settings, segment tooltip).
    var summary: String {
        switch self {
        case .cards: "Frontdoor마다 카드 한 장, 움직이는 Worker와 상태"
        case .graph: "Frontdoor → Worker 호출 관계를 한 장의 그래프로"
        case .sequence: "세션별 레인에 이벤트와 호출·응답을 시간순으로"
        }
    }
}

/// Builds up to 0.5.0 beta 1 shipped as `ai.creverse.acp-monitor`. macOS 26
/// remembers per bundle identifier whether an app may show in the menu bar,
/// and that identifier ended up hidden, so the app now ships as
/// `ai.creverse.agenlynk`.
/// UserDefaults is keyed by bundle identifier; this carries the old domain's
/// settings (nicknames, dashboard modes, window frames) over once.
enum LegacyDefaultsImport {
    static let legacyDomain = "ai.creverse.acp-monitor"
    static let markerKey = "monitor.legacyDomainImportV1"

    static func run(into defaults: UserDefaults = .standard, from legacy: [String: Any]? = nil) {
        guard !defaults.bool(forKey: markerKey) else { return }
        defer { defaults.set(true, forKey: markerKey) }
        guard let legacy = legacy ?? defaults.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let activeOnly = "monitor.activeOnly"
        static let showThoughts = "monitor.showThoughts"
        static let showToolEvents = "monitor.showToolEvents"
        static let followLatestEvent = "monitor.followLatestEvent"
        static let followLatestEventUXMigration = "monitor.followLatestEventUXMigrationV2"
        static let nodePath = "monitor.nodePath"
        static let petEnabled = "monitor.petEnabled"
        static let petExecutablePath = "monitor.petExecutablePath"
        static let bundledPetDefaultMigration = "monitor.bundledPetDefaultV1"
        static let frontdoorNicknames = "monitor.frontdoorNicknames"
        static let sessionNicknames = "monitor.sessionNicknames"
        static let showSessionColumn = "monitor.showSessionColumn"
        static let showInspectorColumn = "monitor.showInspectorColumn"
        static let dashboardModes = "monitor.dashboardModes"
        static let defaultDashboardMode = "monitor.defaultDashboardMode"
    }

    private let defaults: UserDefaults
    private let bundledPetExecutablePath: String?

    @Published var activeOnly: Bool { didSet { defaults.set(activeOnly, forKey: Key.activeOnly) } }
    @Published var showThoughts: Bool { didSet { defaults.set(showThoughts, forKey: Key.showThoughts) } }
    @Published var showToolEvents: Bool { didSet { defaults.set(showToolEvents, forKey: Key.showToolEvents) } }
    @Published var followLatestEvent: Bool { didSet { defaults.set(followLatestEvent, forKey: Key.followLatestEvent) } }
    /// Dashboard side panels the user wants; the window width may still fold
    /// them away (see DashboardPanelLayout).
    @Published var showSessionColumn: Bool { didSet { defaults.set(showSessionColumn, forKey: Key.showSessionColumn) } }
    @Published var showInspectorColumn: Bool { didSet { defaults.set(showInspectorColumn, forKey: Key.showInspectorColumn) } }
    @Published var nodePath: String { didSet { defaults.set(nodePath, forKey: Key.nodePath) } }
    @Published var petEnabled: Bool { didSet { defaults.set(petEnabled, forKey: Key.petEnabled) } }
    /// Optional custom renderer executable. Empty selects Lynk's bundled Pet.
    @Published var petExecutablePath: String { didSet { defaults.set(petExecutablePath, forKey: Key.petExecutablePath) } }

    /// User-chosen Frontdoor names, keyed by openerInstanceId. The auto name
    /// (working folder) is only a default; a person can override it and it
    /// persists here. A UI preference, so it lives in UserDefaults, not on the
    /// Gateway.
    @Published private(set) var frontdoorNicknames: [String: String] {
        didSet {
            defaults.set(try? JSONEncoder().encode(frontdoorNicknames), forKey: Key.frontdoorNicknames)
        }
    }
    /// User-chosen session names, keyed by monitor session id — a store of
    /// their own, so no Frontdoor id can ever collide with a session id.
    @Published private(set) var sessionNicknames: [String: String] {
        didSet {
            defaults.set(try? JSONEncoder().encode(sessionNicknames), forKey: Key.sessionNicknames)
        }
    }

    /// Dashboard views the user keeps, in segment order; never empty.
    @Published private(set) var enabledDashboardModes: [DashboardMode] {
        didSet { defaults.set(enabledDashboardModes.map(\.rawValue), forKey: Key.dashboardModes) }
    }
    /// The view a launch opens on; always one of `enabledDashboardModes`.
    @Published private(set) var defaultDashboardMode: DashboardMode {
        didSet { defaults.set(defaultDashboardMode.rawValue, forKey: Key.defaultDashboardMode) }
    }
    /// The view last picked in this launch. In memory only: reopening the
    /// dashboard window keeps it, the next launch starts at the default.
    @Published var lastDashboardMode: DashboardMode?
    /// Whether the 그래프 / 시퀀스 views have their "대기 중 Worker" box open.
    /// In memory only, like `lastDashboardMode`: every launch starts folded.
    @Published var showRestingGraphWorkers = false
    @Published var showRestingSequenceLanes = false

    /// The view to show: the one picked this launch while it stays enabled,
    /// else the default.
    var currentDashboardMode: DashboardMode {
        if let lastDashboardMode, enabledDashboardModes.contains(lastDashboardMode) { return lastDashboardMode }
        return defaultDashboardMode
    }

    func isDashboardModeEnabled(_ mode: DashboardMode) -> Bool { enabledDashboardModes.contains(mode) }

    /// Turn a view on or off. The last enabled view cannot be turned off; a
    /// default that is turned off falls back to the first view still on.
    func setDashboardMode(_ mode: DashboardMode, enabled: Bool) {
        var next = Set(enabledDashboardModes)
        if enabled { next.insert(mode) } else { next.remove(mode) }
        guard !next.isEmpty else { return }
        enabledDashboardModes = DashboardMode.allCases.filter(next.contains)
        if !next.contains(defaultDashboardMode) { defaultDashboardMode = enabledDashboardModes[0] }
    }

    /// Only an enabled view can be the default.
    func setDefaultDashboardMode(_ mode: DashboardMode) {
        guard enabledDashboardModes.contains(mode) else { return }
        defaultDashboardMode = mode
    }

    private static func loadDashboardModes(_ defaults: UserDefaults) -> (enabled: [DashboardMode], preferred: DashboardMode) {
        let stored = Set((defaults.stringArray(forKey: Key.dashboardModes) ?? []).compactMap(DashboardMode.init(rawValue:)))
        let enabled = stored.isEmpty ? DashboardMode.allCases : DashboardMode.allCases.filter(stored.contains)
        let preferred = defaults.string(forKey: Key.defaultDashboardMode).flatMap(DashboardMode.init(rawValue:))
        // The sequence was the only view before; it stays the first-run default.
        let fallback: DashboardMode = enabled.contains(.sequence) ? .sequence : enabled[0]
        return (enabled, preferred.flatMap { enabled.contains($0) ? $0 : nil } ?? fallback)
    }

    func sessionNickname(id: String) -> String? {
        let value = sessionNicknames[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// Save a session name, or clear it (back to the automatic name) when empty.
    func setSessionNickname(_ name: String?, id: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            sessionNicknames.removeValue(forKey: id)
        } else {
            sessionNicknames[id] = trimmed
        }
    }

    /// The name to show for a Frontdoor: the user's override when set,
    /// otherwise the auto-derived name the caller passes in.
    func frontdoorName(id: String, auto: String) -> String {
        let override = frontdoorNicknames[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (override?.isEmpty == false) ? override! : auto
    }

    func hasFrontdoorNickname(id: String) -> Bool {
        (frontdoorNicknames[id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    /// Save a name, or clear the override (revert to auto) when passed empty.
    func setFrontdoorName(_ name: String?, id: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            frontdoorNicknames.removeValue(forKey: id)
        } else {
            frontdoorNicknames[id] = trimmed
        }
    }

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
        showSessionColumn = defaults.object(forKey: Key.showSessionColumn) as? Bool ?? true
        showInspectorColumn = defaults.object(forKey: Key.showInspectorColumn) as? Bool ?? true
        showThoughts = defaults.object(forKey: Key.showThoughts) as? Bool ?? true
        showToolEvents = defaults.object(forKey: Key.showToolEvents) as? Bool ?? true
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
        let dashboardModes = Self.loadDashboardModes(defaults)
        enabledDashboardModes = dashboardModes.enabled
        defaultDashboardMode = dashboardModes.preferred
        if let data = defaults.data(forKey: Key.sessionNicknames),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            sessionNicknames = decoded
        } else {
            sessionNicknames = [:]
        }
        if let data = defaults.data(forKey: Key.frontdoorNicknames),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            frontdoorNicknames = decoded
        } else {
            frontdoorNicknames = [:]
        }
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
        followLatestEvent = false
        nodePath = ""
        enabledDashboardModes = DashboardMode.allCases
        defaultDashboardMode = .sequence
        lastDashboardMode = nil
        petEnabled = bundledPetExecutablePath != nil
        petExecutablePath = ""
    }
}
