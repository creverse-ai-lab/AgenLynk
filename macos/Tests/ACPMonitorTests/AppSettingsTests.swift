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

        print("Swift settings checks passed")
    }
}

private enum SettingsCheckError: Error {
    case failed(String)
}
