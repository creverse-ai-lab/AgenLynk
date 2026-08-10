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
        defaults.set("/tmp/custom-watcher-project", forKey: "monitor.petWatcherProjectPath")
        defaults.set(true, forKey: "monitor.followLatestEvent")

        let settings = AppSettings(defaults: defaults)
        guard !settings.followLatestEvent else {
            throw SettingsCheckError.failed("follow-latest UX migration must start disabled")
        }
        guard settings.petExecutablePath == "/tmp/custom-pet",
              settings.petWatcherProjectPath == "/tmp/custom-watcher-project" else {
            throw SettingsCheckError.failed("Pet paths must load from stored defaults, not a hard-coded developer path")
        }
        settings.reset()

        guard !settings.petEnabled,
              !settings.followLatestEvent,
              settings.petExecutablePath.isEmpty,
              settings.petWatcherProjectPath.isEmpty,
              defaults.bool(forKey: "monitor.petEnabled") == false,
              defaults.string(forKey: "monitor.petExecutablePath") == "",
              defaults.string(forKey: "monitor.petWatcherProjectPath") == "" else {
            throw SettingsCheckError.failed("reset must disable Pet and clear its executable/watcher paths, with no hard-coded default")
        }
        print("Swift settings checks passed")
    }
}

private enum SettingsCheckError: Error {
    case failed(String)
}
