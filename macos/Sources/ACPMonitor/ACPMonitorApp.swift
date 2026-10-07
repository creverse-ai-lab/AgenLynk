import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var launchHandler: (@MainActor () -> Void)?
    var terminationHandler: (() async -> Void)?
    private var terminating = false

    /// Connect to the Gateway at launch, not when a window first appears. The
    /// dashboard and the popover also call startIfNeeded(), but neither is on
    /// screen at launch unless macOS restores the dashboard, so without this
    /// the app could sit unconnected with no sidecar until clicked.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { launchHandler?() }
    }

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
    /// The menu bar switch alone (see MenuBarVisibility).
    @StateObject private var menuBar: MenuBarVisibility

    init() {
        // Before AppModel reads any setting.
        LegacyDefaultsImport.run()
        LaunchServicesHygiene.runOncePerBuild()
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _menuBar = StateObject(wrappedValue: MenuBarVisibility(settings: model.settings))
        appDelegate.launchHandler = { [weak model] in
            ProviderIcon.registerMascotMarks()
            model?.startIfNeeded()
            if model?.settings.notchEnabled == true { model?.notchChat.show() }
        }
        appDelegate.terminationHandler = { [weak model] in await model?.stop() }
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: the dashboard is a single, unique
        // window. A WindowGroup is a template that spawns a fresh window on
        // every openWindow(id:), which is why "대시보드 열기" from the menu bar
        // stacked duplicates instead of focusing the one already open. `Window`
        // makes openWindow(id:) bring the existing window forward.
        Window("AgenLynk", id: "dashboard") {
            WhileWindowOpen {
                DashboardView()
                    .environmentObject(model)
                    .environmentObject(model.settings)
            }
        }
        .defaultSize(width: 1420, height: 880)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("설정…") { model.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        // Live monitoring is the menu-bar popover now; a separate Monitoring
        // window showed the same projection twice.
        WindowGroup("Session", id: "session-detail", for: String.self) { sessionId in
            WhileWindowOpen {
                SessionDetailView(sessionId: sessionId.wrappedValue)
                    .environmentObject(model)
                    .environmentObject(model.settings)
            }
        }
        .defaultSize(width: 1040, height: 720)

        // No Settings scene: its window stays alive after closing and keeps
        // re-rendering. 설정… (⌘,) opens the same released-on-close window as
        // every other entry point.

        MenuBarExtra(isInserted: Binding(
            get: { menuBar.isVisible },
            set: { menuBar.set($0) }
        )) {
            WhileWindowOpen {
                MenuBarStatusView()
                    .environmentObject(model)
                    .environmentObject(model.settings)
            }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item: the mark, then "main | sub" — how many Frontdoors are
/// working and how many of their Workers are — as bare numbers, with the
/// steps that wait for the user called out after them.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let counts = MenuBarCounts(model.menuBarPipeline)
        HStack(spacing: 3) {
            Image(nsImage: ACPMenuBarIcon.image)
            if let text = counts.text { Text(text).monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(counts.accessibility)
        .help(counts.accessibility)
    }
}

/// Whether the menu bar item is shown, published only when it really changes.
/// MenuBarExtra writes its isInserted binding back as it inserts the item;
/// a source that announces every write (all of AppSettings, or @AppStorage)
/// re-ran the scene, which re-inserted the item, without end.
@MainActor
final class MenuBarVisibility: ObservableObject {
    @Published private(set) var isVisible: Bool
    private let settings: AppSettings
    private var subscription: AnyCancellable?

    init(settings: AppSettings) {
        self.settings = settings
        isVisible = settings.menuBarEnabled
        subscription = settings.$menuBarEnabled
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self, self.isVisible != visible else { return }
                self.isVisible = visible
            }
    }

    func set(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if settings.menuBarEnabled != visible { settings.menuBarEnabled = visible }
    }
}

/// A scene's content only while its window is open. SwiftUI keeps a closed
/// Window, WindowGroup or menu bar window alive and goes on re-rendering its
/// content on every model change for the rest of the app's life: a closed
/// dashboard redrew ~10 times a second. Measured in a probe app: closed, 105
/// renders per 10 s without this, none with it; reopened, rendered again.
struct WhileWindowOpen<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var open = true

    var body: some View {
        ZStack {
            if open { content() } else { Color.clear }
        }
        .onAppear { open = true }
        .onDisappear { open = false }
    }
}
