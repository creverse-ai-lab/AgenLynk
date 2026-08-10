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
        print("Swift settings checks passed")
    }
}

private enum SettingsCheckError: Error {
    case failed(String)
}
