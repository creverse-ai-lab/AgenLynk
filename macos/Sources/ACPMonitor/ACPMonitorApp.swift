import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() -> Void)?
    func applicationWillTerminate(_ notification: Notification) { terminationHandler?() }
}

@main
struct ACPMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Lynk", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .onAppear { appDelegate.terminationHandler = { model.stop() } }
        }
        .defaultSize(width: 1420, height: 880)

        Window("Lynk Monitoring", id: "live-graph") {
            LiveGraphView().environmentObject(model).environmentObject(model.settings)
        }
        .defaultSize(width: 1320, height: 820)

        WindowGroup("Session", id: "session-detail", for: String.self) { sessionId in
            SessionDetailView(sessionId: sessionId.wrappedValue)
                .environmentObject(model)
                .environmentObject(model.settings)
        }
        .defaultSize(width: 1040, height: 720)

        Settings {
            SettingsView().environmentObject(model).environmentObject(model.settings)
        }
    }
}
