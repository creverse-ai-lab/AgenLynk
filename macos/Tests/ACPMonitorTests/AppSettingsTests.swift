import Foundation

@main
enum AppSettingsChecks {
    @MainActor
    static func main() throws {
        let suite = scratchSuite("Settings")
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw SettingsCheckError.failed("could not create isolated defaults")
        }
        defer { discardSuite(suite, defaults) }
        defaults.set(true, forKey: "monitor.petEnabled")
        defaults.set("/tmp/custom-pet", forKey: "monitor.petExecutablePath")
        defaults.set(true, forKey: "monitor.followLatestEvent")

        let settings = AppSettings(defaults: defaults)
        guard !settings.followLatestEvent else {
            throw SettingsCheckError.failed("follow-latest UX migration must start disabled")
        }
        guard settings.petExecutablePath == "/tmp/custom-pet" else {
            throw SettingsCheckError.failed("the Pet path must load from stored defaults, not a hard-coded developer path")
        }
        settings.reset()

        guard !settings.petEnabled,
              !settings.followLatestEvent,
              settings.petExecutablePath.isEmpty,
              defaults.bool(forKey: "monitor.petEnabled") == false,
              defaults.string(forKey: "monitor.petExecutablePath") == "" else {
            throw SettingsCheckError.failed("reset must disable Pet and clear its executable path, with no hard-coded default")
        }

        // "mochi" named the devil before the mermaid joined it.
        defaults.set("mochi", forKey: "monitor.petStyle")
        guard AppSettings(defaults: defaults).petStyle == .devil else {
            throw SettingsCheckError.failed("a stored mochi pet style must load as the devil")
        }
        defaults.set("mermaid", forKey: "monitor.petStyle")
        guard AppSettings(defaults: defaults).petStyle == .mermaid, PetStyle.allCases == [.orbit, .devil, .mermaid] else {
            throw SettingsCheckError.failed("the pet has three looks: orbit, devil and mermaid")
        }
        defaults.removeObject(forKey: "monitor.petStyle")

        defaults.set(true, forKey: "monitor.petEnabled")
        defaults.set("   ", forKey: "monitor.petExecutablePath")
        let migratedSettings = AppSettings(defaults: defaults)
        guard !migratedSettings.petEnabled,
              defaults.bool(forKey: "monitor.petEnabled") == false else {
            throw SettingsCheckError.failed("an enabled Pet without an executable path must migrate to disabled")
        }

        let bundledSuite = scratchSuite("Bundled")
        guard let bundledDefaults = UserDefaults(suiteName: bundledSuite) else {
            throw SettingsCheckError.failed("could not create bundled Pet defaults")
        }
        defer { discardSuite(bundledSuite, bundledDefaults) }
        let bundledPath = "/Applications/Lynk.app/Contents/Helpers/LynkPet.app/Contents/MacOS/LynkPet"
        let bundledSettings = AppSettings(defaults: bundledDefaults, bundledPetExecutablePath: bundledPath)
        guard bundledSettings.petEnabled,
              bundledSettings.usesBundledPet,
              bundledSettings.resolvedPetExecutablePath == bundledPath,
              bundledSettings.petExecutablePath.isEmpty else {
            throw SettingsCheckError.failed("a packaged Lynk Pet must be enabled by default without persisting its bundle path")
        }
        bundledSettings.petEnabled = false
        let relaunchedSettings = AppSettings(defaults: bundledDefaults, bundledPetExecutablePath: bundledPath)
        guard !relaunchedSettings.petEnabled else {
            throw SettingsCheckError.failed("an explicit Pet Off choice must survive relaunch after the default migration")
        }
        // Frontdoor rename: auto by default, override persists, empty reverts.
        let nickSuite = scratchSuite("Nick")
        guard let nickDefaults = UserDefaults(suiteName: nickSuite) else {
            throw SettingsCheckError.failed("could not create nickname defaults")
        }
        defer { discardSuite(nickSuite, nickDefaults) }
        let nick = AppSettings(defaults: nickDefaults)
        guard nick.frontdoorName(id: "main-1", auto: "proj") == "proj", !nick.hasFrontdoorNickname(id: "main-1") else {
            throw SettingsCheckError.failed("an un-renamed Frontdoor must show its auto name")
        }
        nick.setFrontdoorName("코드리뷰 봇", id: "main-1")
        guard nick.frontdoorName(id: "main-1", auto: "proj") == "코드리뷰 봇", nick.hasFrontdoorNickname(id: "main-1") else {
            throw SettingsCheckError.failed("a set name must override the auto name")
        }
        let reloaded = AppSettings(defaults: nickDefaults)
        guard reloaded.frontdoorName(id: "main-1", auto: "proj") == "코드리뷰 봇" else {
            throw SettingsCheckError.failed("a Frontdoor name must survive relaunch")
        }
        reloaded.setFrontdoorName("   ", id: "main-1")
        guard reloaded.frontdoorName(id: "main-1", auto: "proj") == "proj", !reloaded.hasFrontdoorNickname(id: "main-1") else {
            throw SettingsCheckError.failed("clearing a name must revert to the auto name")
        }

        try dashboardModeChecks()
        try legacyDefaultsImportChecks()
        try surfaceChecks()
        print("Swift settings checks passed")
    }
}

/// Menu bar, notch and pet each have their own switch: all on by default,
/// each remembered, the notch's old reply switch carried over, and reset
/// turns everything back on.
@MainActor
private func surfaceChecks() throws {
    let suite = scratchSuite("surfaces")
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw SettingsCheckError.failed("could not create isolated defaults")
    }
    defer { discardSuite(suite, defaults) }
    let fresh = AppSettings(defaults: defaults, bundledPetExecutablePath: nil)
    guard fresh.menuBarEnabled, fresh.notchEnabled, fresh.notchAlertsEnabled, fresh.notchSoundsEnabled, fresh.notchRepliesEnabled else {
        throw SettingsCheckError.failed("every surface starts on")
    }
    fresh.menuBarEnabled = false
    fresh.notchAlertsEnabled = false
    let reloaded = AppSettings(defaults: defaults, bundledPetExecutablePath: nil)
    guard !reloaded.menuBarEnabled, !reloaded.notchAlertsEnabled, reloaded.notchEnabled else {
        throw SettingsCheckError.failed("surface switches survive relaunch, one at a time")
    }
    reloaded.reset()
    guard reloaded.menuBarEnabled, reloaded.notchAlertsEnabled else {
        throw SettingsCheckError.failed("reset turns the surfaces back on")
    }

    let legacySuite = "\(suite).legacy"
    guard let legacy = UserDefaults(suiteName: legacySuite) else {
        throw SettingsCheckError.failed("could not create isolated defaults")
    }
    defer { discardSuite(legacySuite, legacy) }
    legacy.set(false, forKey: "notchRepliesEnabled")
    guard !AppSettings(defaults: legacy, bundledPetExecutablePath: nil).notchRepliesEnabled else {
        throw SettingsCheckError.failed("the notch's earlier reply switch is kept")
    }
}

/// Dashboard views: at least one stays on, the default is always an enabled
/// one, and the choice survives relaunch while the last-picked view does not.
@MainActor
private func dashboardModeChecks() throws {
    let suite = scratchSuite("Dashboard")
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw SettingsCheckError.failed("could not create dashboard defaults")
    }
    defer { discardSuite(suite, defaults) }
    let settings = AppSettings(defaults: defaults)
    guard settings.enabledDashboardModes == DashboardMode.allCases,
          settings.defaultDashboardMode == .sequence,
          settings.currentDashboardMode == .sequence else {
        throw SettingsCheckError.failed("a first run offers every view and opens on the sequence")
    }
    settings.setDefaultDashboardMode(.graph)
    settings.setDashboardMode(.graph, enabled: false)
    guard settings.enabledDashboardModes == [.cards, .sequence], settings.defaultDashboardMode == .cards else {
        throw SettingsCheckError.failed("turning off the default falls back to the first view still on")
    }
    settings.setDashboardMode(.sequence, enabled: false)
    settings.setDashboardMode(.cards, enabled: false)
    guard settings.enabledDashboardModes == [.cards], settings.defaultDashboardMode == .cards else {
        throw SettingsCheckError.failed("the last enabled view cannot be turned off")
    }
    settings.setDefaultDashboardMode(.sequence)
    guard settings.defaultDashboardMode == .cards else {
        throw SettingsCheckError.failed("a disabled view cannot become the default")
    }
    settings.setDashboardMode(.sequence, enabled: true)
    settings.lastDashboardMode = .sequence
    guard settings.currentDashboardMode == .sequence else {
        throw SettingsCheckError.failed("the view picked this launch is the one shown")
    }
    settings.setDashboardMode(.sequence, enabled: false)
    guard settings.currentDashboardMode == .cards else {
        throw SettingsCheckError.failed("a picked view that is turned off gives way to the default")
    }
    settings.setDashboardMode(.graph, enabled: true)
    settings.lastDashboardMode = .graph
    let relaunched = AppSettings(defaults: defaults)
    guard relaunched.enabledDashboardModes == [.cards, .graph],
          relaunched.defaultDashboardMode == .cards,
          relaunched.lastDashboardMode == nil,
          relaunched.currentDashboardMode == .cards else {
        throw SettingsCheckError.failed("enabled views and the default persist; the last-picked view is per launch")
    }

    // Stored values that make no sense recover instead of leaving no view.
    defaults.set(["bogus"], forKey: "monitor.dashboardModes")
    defaults.set("graph", forKey: "monitor.defaultDashboardMode")
    let recovered = AppSettings(defaults: defaults)
    guard recovered.enabledDashboardModes == DashboardMode.allCases, recovered.defaultDashboardMode == .graph else {
        throw SettingsCheckError.failed("an unreadable view list falls back to every view")
    }
    defaults.set(["cards"], forKey: "monitor.dashboardModes")
    let stale = AppSettings(defaults: defaults)
    guard stale.defaultDashboardMode == .cards else {
        throw SettingsCheckError.failed("a stored default that is not enabled falls back to an enabled view")
    }
    stale.reset()
    guard stale.enabledDashboardModes == DashboardMode.allCases, stale.defaultDashboardMode == .sequence else {
        throw SettingsCheckError.failed("reset restores every view and the sequence default")
    }
}

/// The old bundle identifier's settings come over once, never over a value
/// the new identifier already has.
private func legacyDefaultsImportChecks() throws {
    let suite = scratchSuite("Legacy")
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw SettingsCheckError.failed("could not create legacy import defaults")
    }
    defer { discardSuite(suite, defaults) }
    defaults.set(false, forKey: "monitor.showThoughts")
    LegacyDefaultsImport.run(into: defaults, from: [
        "monitor.showThoughts": true,
        "monitor.frontdoorNicknames": ["fd-1": "api"],
        "NSStatusItem VisibleCC Item-0": false
    ])
    guard defaults.object(forKey: "NSStatusItem VisibleCC Item-0") == nil else {
        throw SettingsCheckError.failed("a status item hidden under the old identifier must not stay hidden")
    }
    guard defaults.bool(forKey: "monitor.showThoughts") == false,
          defaults.dictionary(forKey: "monitor.frontdoorNicknames") as? [String: String] == ["fd-1": "api"],
          defaults.bool(forKey: LegacyDefaultsImport.markerKey) else {
        throw SettingsCheckError.failed("legacy settings fill only missing keys and mark the import done")
    }
    LegacyDefaultsImport.run(into: defaults, from: ["monitor.nodePath": "/tmp/node"])
    guard defaults.object(forKey: "monitor.nodePath") == nil else {
        throw SettingsCheckError.failed("the legacy import runs once")
    }
}

private enum SettingsCheckError: Error {
    case failed(String)
}

/// A defaults suite for one test, kept out of ~/Library/Preferences: a suite
/// named by an absolute path lives in that file, so every run's scratch
/// settings go to the temporary folder instead of piling up (cfprefsd writes
/// an empty plist back for a removed domain, after any attempt to delete it).
func scratchSuite(_ label: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ACPMonitor.AppSettingsTests.\(label).\(UUID().uuidString)").path
}

/// Drops a scratch defaults suite and its file.
func discardSuite(_ name: String, _ defaults: UserDefaults) {
    defaults.removePersistentDomain(forName: name)
    try? FileManager.default.removeItem(atPath: name + ".plist")
}
