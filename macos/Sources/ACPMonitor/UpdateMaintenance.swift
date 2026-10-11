import Darwin
import Foundation

/// What an app installed over an older one cleans up, once per build: the
/// old build's helper processes, its Gateway runtime, MCP entries that point
/// at a runtime that is gone, and runtime versions nobody uses any more. Each
/// of these broke something after an update before (a Pet that would not
/// start, a Main without the new front door, a CLI whose MCP could not start,
/// hundreds of MB per old runtime). The decisions are pure and tested here;
/// AppModel runs them once the monitor knows whether the Gateway is busy.
enum UpdateMaintenance {
    static let markerKey = "monitor.updateMaintenanceBuild"
    /// How often a maintenance the Gateway's work held back is tried again.
    static let retryInterval: UInt64 = 10 * 60 * 1_000_000_000

    /// This build, as the marker records it.
    static func build(_ bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?")+\(info?["CFBundleVersion"] as? String ?? "?")"
    }

    /// Whether the runtime this app ships should replace the current one: only
    /// a newer Gateway, and never one the person pinned by rolling back.
    static func shouldActivateSeed(current: String?, seed: String?, pinned: Bool) -> Bool {
        guard !pinned, let seed else { return false }
        guard let current else { return true }
        return compareSemanticVersions(current, seed) == .orderedAscending
    }

    /// Monitor sidecars any AgenLynk build started whose app is gone (their
    /// parent is launchd), from `ps -axo pid=,ppid=,command=`. Ours is skipped.
    static func orphanedSidecars(psOutput: String, own: pid_t?) -> [pid_t] {
        psOutput.split(separator: "\n").compactMap { line -> pid_t? in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]),
                  parent == 1, pid != own,
                  fields[2].contains("/Contents/Resources/sidecar/src/server/monitor.js") else { return nil }
            return pid
        }
    }

    /// The process table as `ps` prints it, or "" when it cannot run.
    static func processTable() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The one line the notice log keeps of what was done.
    static func summary(endedProcesses: Int, activated: String?, relinked: Bool, freed: String?) -> String? {
        var parts: [String] = []
        if endedProcesses > 0 { parts.append("남아 있던 이전 버전 프로세스 \(endedProcesses)개 종료") }
        if let activated { parts.append("Gateway 런타임 \(activated) 적용") }
        if relinked { parts.append("MCP 항목 다시 등록") }
        if let freed { parts.append("옛 런타임 정리(\(freed) 확보)") }
        guard !parts.isEmpty else { return nil }
        // The CLIs start their Gateway front door when they start.
        let hint = activated == nil ? "" : ". 열려 있는 Claude · Codex · Grok CLI를 다시 시작하면 새 Gateway를 씁니다."
        return "업데이트 정리: " + parts.joined(separator: " · ") + hint
    }
}
