import AppKit

/// One AgenLynk at a time. A second copy (an old build in Downloads, one
/// opened straight from the mounted DMG) kept its own notch, menu bar item,
/// sidecar and Pet: quitting one left the other's on screen, and the two
/// Pets fought over one lock. The copy in Applications wins; any other copy
/// hands over to the one already running and quits.
enum SingleInstance {
    enum Decision: Equatable {
        /// Nothing else runs.
        case proceed
        /// This copy is the installed one: the others are asked to quit.
        case replace([pid_t])
        /// Another copy runs and this one is not the installed one.
        case yield(to: pid_t)
    }

    /// `others` are the other running copies (pid and bundle path).
    static func decide(ownPath: String, others: [(pid: pid_t, path: String?)]) -> Decision {
        guard let first = others.first else { return .proceed }
        let installed = BundledRuntime.isStableApplicationPath(ownPath)
        // Two installed copies: the one already running stays.
        let differentCopies = others.filter { $0.path.map { $0 != ownPath } ?? true }
        if installed, differentCopies.count == others.count {
            return .replace(others.map(\.pid))
        }
        return .yield(to: first.pid)
    }

    /// Runs at launch, before the app starts anything. Returns false when
    /// this copy is quitting in favour of the one already running.
    @MainActor
    static func claim() -> Bool {
        let own = NSRunningApplication.current
        guard let identifier = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != own.processIdentifier && !$0.isTerminated }
        switch decide(ownPath: Bundle.main.bundleURL.standardizedFileURL.path,
                      others: others.map { ($0.processIdentifier, $0.bundleURL?.standardizedFileURL.path) }) {
        case .proceed:
            return true
        case let .replace(pids):
            for app in others where pids.contains(app.processIdentifier) {
                app.terminate()
            }
            // A copy that does not quit within a few seconds is ended.
            let deadline = Date().addingTimeInterval(4)
            while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            for app in others where !app.isTerminated { app.forceTerminate() }
            return true
        case let .yield(to: pid):
            NSRunningApplication(processIdentifier: pid)?.activate()
            return false
        }
    }
}
