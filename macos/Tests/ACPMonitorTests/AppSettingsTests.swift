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
        defaults.set("/tmp/custom-pet", forKey: "monitor.petProjectPath")
        defaults.set(true, forKey: "monitor.followLatestEvent")

        let settings = AppSettings(defaults: defaults)
        guard !settings.followLatestEvent else {
            throw SettingsCheckError.failed("follow-latest UX migration must start disabled")
        }
        settings.reset()

        guard !settings.petEnabled,
              !settings.followLatestEvent,
              settings.petProjectPath == AppSettings.defaultPetProjectPath,
              defaults.bool(forKey: "monitor.petEnabled") == false,
              defaults.string(forKey: "monitor.petProjectPath") == AppSettings.defaultPetProjectPath else {
            throw SettingsCheckError.failed("reset must disable Pet and restore its default path")
        }
        print("Swift settings checks passed")
    }
}

private enum SettingsCheckError: Error {
    case failed(String)
}
