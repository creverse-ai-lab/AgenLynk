import Foundation

@main
enum AppSettingsChecks {
    @MainActor
    static func main() throws {
        let suite = "ACPMonitor.AppSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw SettingsCheckError.failed("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
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

        defaults.set(true, forKey: "monitor.petEnabled")
        defaults.set("   ", forKey: "monitor.petExecutablePath")
        let migratedSettings = AppSettings(defaults: defaults)
        guard !migratedSettings.petEnabled,
              defaults.bool(forKey: "monitor.petEnabled") == false else {
            throw SettingsCheckError.failed("an enabled Pet without an executable path must migrate to disabled")
        }

        let bundledSuite = "ACPMonitor.AppSettingsTests.Bundled.\(UUID().uuidString)"
        guard let bundledDefaults = UserDefaults(suiteName: bundledSuite) else {
            throw SettingsCheckError.failed("could not create bundled Pet defaults")
        }
        defer { bundledDefaults.removePersistentDomain(forName: bundledSuite) }
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
        let nickSuite = "ACPMonitor.AppSettingsTests.Nick.\(UUID().uuidString)"
        guard let nickDefaults = UserDefaults(suiteName: nickSuite) else {
            throw SettingsCheckError.failed("could not create nickname defaults")
        }
        defer { nickDefaults.removePersistentDomain(forName: nickSuite) }
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
        print("Swift settings checks passed")
    }
}

/// Dashboard views: at least one stays on, the default is always an enabled
/// one, and the choice survives relaunch while the last-picked view does not.
@MainActor
private func dashboardModeChecks() throws {
    let suite = "ACPMonitor.AppSettingsTests.Dashboard.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw SettingsCheckError.failed("could not create dashboard defaults")
    }
    defer { defaults.removePersistentDomain(forName: suite) }
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
    let suite = "ACPMonitor.AppSettingsTests.Legacy.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw SettingsCheckError.failed("could not create legacy import defaults")
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "monitor.showThoughts")
    LegacyDefaultsImport.run(into: defaults, from: [
        "monitor.showThoughts": true,
        "monitor.frontdoorNicknames": ["fd-1": "api"]
    ])
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
