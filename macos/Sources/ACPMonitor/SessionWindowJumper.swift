import AppKit
import ApplicationServices
import Darwin
import SwiftUI

/// Brings forward the window a session runs in: from the agent's process up
/// to the app that hosts it (Warp, VS Code, Terminal, the Claude or Codex
/// app), then, with Accessibility allowed, the one window of that app whose
/// title names the session's folder.
@MainActor
enum SessionWindowJumper {
    enum Outcome: Equatable {
        case window, app, notFound
    }

    static func canJump(_ session: GatewaySession?) -> Bool { session?.pid != nil }

    @discardableResult
    static func jump(to session: GatewaySession) -> Outcome {
        guard let pid = session.pid, let app = hostApp(of: pid_t(pid)) else { return .notFound }
        let raised = !session.cwd.isEmpty && raiseWindow(of: app, cwd: session.cwd)
        bringForward(app)
        return raised ? .window : .app
    }

    /// Since macOS 14 an app that is not active cannot activate another, and
    /// the notch panel never makes AgenLynk active. So AgenLynk takes the
    /// front first and hands it over; if that still did not land, the app is
    /// opened the way the Dock does it.
    private static func bringForward(_ app: NSRunningApplication) {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
        app.activate(options: [.activateAllWindows])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !app.isActive, let url = app.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
    }

    /// The nearest ancestor that is a regular (Dock) app.
    static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<32 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPid(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Needs Accessibility; asks for it once and otherwise just activates the app.
    /// The window whose title names the session: its full path, or else its
    /// folder name when exactly one window has it (a short name like `src`
    /// in several titles is no evidence, and the app is only activated).
    private static func raiseWindow(of app: NSRunningApplication, cwd: String) -> Bool {
        let folder = (cwd as NSString).lastPathComponent
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !askedForAccess] as CFDictionary
        askedForAccess = true
        guard AXIsProcessTrustedWithOptions(options) else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        let titled = windows.compactMap { window -> (AXUIElement, String)? in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return (title as? String).map { (window, $0) }
        }
        let tilde = (cwd as NSString).abbreviatingWithTildeInPath
        let byPath = titled.filter { $0.1.contains(cwd) || $0.1.contains(tilde) }
        let byFolder = titled.filter { $0.1.localizedCaseInsensitiveContains(folder) }
        guard let window = byPath.first?.0 ?? (byFolder.count == 1 ? byFolder.first?.0 : nil) else { return false }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        return true
    }

    private static var askedForAccess = false
}

/// "창으로 이동": the notch card's jump, for the dashboard's Frontdoor list
/// and 현황 cards. Shown only when the session's window can be found.
struct JumpToWindowButton: View {
    let session: GatewaySession?

    var body: some View {
        if let session, SessionWindowJumper.canJump(session) {
            Button {
                SessionWindowJumper.jump(to: session)
            } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .buttonStyle(.borderless)
            .help("이 Frontdoor가 실행 중인 창으로 이동")
            .accessibilityLabel("창으로 이동")
        }
    }
}
