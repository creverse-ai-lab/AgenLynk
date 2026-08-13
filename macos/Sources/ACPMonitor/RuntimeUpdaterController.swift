import Foundation

enum RuntimeUpdaterError: LocalizedError {
    case seedUnavailable
    case processExited(Int32, String)
    case invalidOutput(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .seedUnavailable:
            "이 빌드에는 실행할 Gateway runtime seed가 없습니다."
        case let .processExited(code, detail):
            "runtime updater가 종료되었습니다 (exit \(code)). \(detail)"
        case let .invalidOutput(detail):
            "runtime updater 응답을 해석하지 못했습니다: \(detail)"
        case .timedOut:
            "runtime updater가 응답하지 않아 중단했습니다. 다시 시도해 주세요."
        }
    }
}

/// Runs `runtime-updater-cli.js` from the app's **own bundled seed**, using the
/// seed's Node — the same pattern `RuntimeProvisioner` uses for first install.
///
/// Going through the monitor's HTTP API instead would not work for the case
/// this feature exists for: an existing install whose runtime predates the
/// updater endpoints has a monitor that cannot serve them, so the app could
/// never replace it. The app bundle always carries a current updater, so the
/// seed is the only source that is guaranteed new enough to update from.
///
/// The daemon and monitor still run from the *installed* runtime; only this
/// one-shot operation runs from the seed. Process plumbing (pipes, drain,
/// watchdog) lives in the shared `SeedNodeProcess`.
final class RuntimeUpdaterController {
    private let seedRoot: URL?

    init(seedRoot: URL? = BundledRuntime.seedRuntimeRoot()) {
        self.seedRoot = seedRoot
    }

    var isAvailable: Bool { seedRoot != nil }

    /// `blockers` is passed through to the updater, which refuses to activate
    /// or roll back while any are present.
    func run(_ operation: String, arguments: [String] = [], blockers: [String] = []) async throws -> JSONValue {
        guard let seedRoot else { throw RuntimeUpdaterError.seedUnavailable }
        var argv = [operation] + arguments
        if !blockers.isEmpty {
            argv += ["--blockers", String(decoding: try JSONEncoder().encode(blockers), as: UTF8.self)]
        }

        let result: SeedNodeProcess.Result
        do {
            result = try await SeedNodeProcess.run(
                seedRoot: seedRoot,
                script: "app-runtime/runtime-updater-cli.js",
                arguments: argv,
                timeout: 120
            )
        } catch SeedNodeProcessError.timedOut {
            throw RuntimeUpdaterError.timedOut
        } catch is SeedNodeProcessError {
            throw RuntimeUpdaterError.seedUnavailable
        }

        // The CLI prints exactly one JSON envelope for success and for expected
        // failure alike, and only sets a nonzero exit code alongside it — so a
        // parseable envelope is authoritative even when the exit code is 1.
        let text = result.stdoutText
        guard let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let value = JSONValue(any: parsed).objectValue else {
            if result.terminationStatus != 0 {
                throw RuntimeUpdaterError.processExited(result.terminationStatus, result.stderrTail)
            }
            throw RuntimeUpdaterError.invalidOutput(String(text.suffix(500)))
        }
        return .object(value)
    }
}
