import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() async -> Void)?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler, !terminating else { return terminating ? .terminateLater : .terminateNow }
        terminating = true
        Task {
            await terminationHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ACPMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.terminationHandler = { [weak model] in await model?.stop() }
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: the dashboard is a single, unique
        // window. A WindowGroup is a template that spawns a fresh window on
        // every openWindow(id:), which is why "대시보드 열기" from the menu bar
        // stacked duplicates instead of focusing the one already open. `Window`
        // makes openWindow(id:) bring the existing window forward.
        Window("AgenLynk", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
        .defaultSize(width: 1420, height: 880)

        // Live monitoring is the menu-bar popover now; a separate Monitoring
        // window showed the same projection twice.
        WindowGroup("Session", id: "session-detail", for: String.self) { sessionId in
            SessionDetailView(sessionId: sessionId.wrappedValue)
                .environmentObject(model)
                .environmentObject(model.settings)
        }
        .defaultSize(width: 1040, height: 720)

        Settings {
            SettingsView().environmentObject(model).environmentObject(model.settings)
        }

        MenuBarExtra {
            MenuBarStatusView()
                .environmentObject(model)
                .environmentObject(model.settings)
        } label: {
            Image(nsImage: ACPMenuBarIcon.image)
                .accessibilityLabel("AgenLynk")
        }
        .menuBarExtraStyle(.window)
    }
}
