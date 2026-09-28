import Foundation

/// Only dead or transient copies of our own identifiers are dropped; the
/// running app, its nested Pet, and other apps are never touched.
@main
enum LaunchServicesHygieneChecks {
    static func main() throws {
        let dump = """
        --------------------------------------------------------------------------------
        bundle id:                  1
        path:                       /Applications/AgenLynk.app (0xa04c)
        identifier:                 ai.creverse.agenlynk
        --------------------------------------------------------------------------------
        path:                       /Applications/AgenLynk.app/Contents/Helpers/LynkPet.app (0xa050)
        identifier:                 ai.creverse.agenlynk.pet
        --------------------------------------------------------------------------------
        path:                       /Users/me/old/AgenLynk.app (0x6e2c)
        identifier:                 ai.creverse.acp-monitor
        --------------------------------------------------------------------------------
        path:                       /Users/me/kept/AgenLynk.app (0x6e30)
        identifier:                 ai.creverse.acp-monitor
        --------------------------------------------------------------------------------
        path:                       /Volumes/AgenLynk/AgenLynk.app (0x9f84)
        identifier:                 ai.creverse.agenlynk
        --------------------------------------------------------------------------------
        path:                       /private/var/folders/ld/T/acp-lynk-dmg-verify.AB12/AgenLynk.app/Contents/Helpers/LynkPet.app (0x1)
        identifier:                 ai.creverse.acp-monitor.pet
        --------------------------------------------------------------------------------
        path:                       /Users/me/gone/Other.app (0x2)
        identifier:                 com.example.other
        """
        let alive: Set<String> = [
            "/Applications/AgenLynk.app",
            "/Applications/AgenLynk.app/Contents/Helpers/LynkPet.app",
            "/Users/me/kept/AgenLynk.app",
            "/Volumes/AgenLynk/AgenLynk.app"
        ]
        let stale = LaunchServicesHygiene.stalePaths(in: dump, keeping: "/Applications/AgenLynk.app", exists: alive.contains)
        let expected = [
            "/Users/me/old/AgenLynk.app",
            "/Volumes/AgenLynk/AgenLynk.app",
            "/private/var/folders/ld/T/acp-lynk-dmg-verify.AB12/AgenLynk.app/Contents/Helpers/LynkPet.app"
        ].sorted()
        guard stale == expected else {
            throw CheckError.failed("stale Launch Services records: expected \(expected), got \(stale)")
        }
        print("Swift Launch Services hygiene checks passed")
    }
}

private enum CheckError: Error {
    case failed(String)
}
