import AppKit
import SwiftUI

/// Settings in a window of its own, for callers outside the SwiftUI scenes
/// (the notch panel). macOS 14 dropped `showSettingsWindow:`, and the
/// Settings scene's opener only exists inside a scene, which the notch is not.
@MainActor
final class SettingsWindowPresenter {
    private var window: NSWindow?

    func show(model: AppModel, tab: SettingsTab) {
        // A window already open still switches to the tab asked for.
        if let window {
            window.contentView = NSHostingView(rootView: SettingsView(initialTab: tab)
                .environmentObject(model)
                .environmentObject(model.settings))
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "AgenLynk 설정"
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("agenlynk-settings")
            window.contentView = NSHostingView(rootView: SettingsView(initialTab: tab)
                .environmentObject(model)
                .environmentObject(model.settings))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Session detail windows for callers outside the SwiftUI scenes (the
/// notch). The scene's `openWindow` lived only in the menu bar label, so with
/// the menu bar turned off nothing opened them. One window per session,
/// let go when it closes: a closed window kept its SessionDetailView, which
/// observes the whole AppModel, alive for the rest of the app's life.
@MainActor
final class SessionDetailWindowPresenter {
    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    func show(model: AppModel, sessionId: String) {
        let window = windows[sessionId] ?? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Session"
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("session-detail-\(sessionId)")
            window.contentView = NSHostingView(rootView: SessionDetailView(sessionId: sessionId)
                .environmentObject(model)
                .environmentObject(model.settings))
            window.center()
            windows[sessionId] = window
            closeObservers[sessionId] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                // Let go after the close finishes: this dictionary is the
                // window's only owner, and AppKit is still closing it here.
                DispatchQueue.main.async { self?.release(sessionId) }
            }
            return window
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func release(_ sessionId: String) {
        if let observer = closeObservers.removeValue(forKey: sessionId) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows.removeValue(forKey: sessionId)?.contentView = nil
    }
}
