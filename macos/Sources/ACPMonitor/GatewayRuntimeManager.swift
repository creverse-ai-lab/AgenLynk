import Foundation

enum GatewayRuntimeChangeOutcome: Equatable, Sendable {
    case activated(String)
    case rolledBack(String?)
    case alreadyCurrent(String)
    case blocked
    case noPrevious
    case failed(String)
}

struct GatewayRuntimeChange: Equatable, Sendable {
    let outcome: GatewayRuntimeChangeOutcome
    let inspection: RuntimeInspection?
}

/// Owns runtime seed discovery and every stage/activate/rollback operation.
/// The UI model supplies only the current blocker snapshot and renders the
/// returned domain outcome.
actor GatewayRuntimeManager {
    nonisolated let isAvailable: Bool
    nonisolated let seedGatewayVersion: SeedGatewayVersion?

    private let seedRoot: URL?
    private let updater: RuntimeUpdaterController

    init(seedRoot: URL? = BundledRuntime.seedRuntimeRoot()) {
        self.seedRoot = seedRoot
        updater = RuntimeUpdaterController(seedRoot: seedRoot)
        isAvailable = seedRoot != nil
        if let manifest = seedRoot?.appendingPathComponent("runtime-manifest.json"),
           let data = try? Data(contentsOf: manifest) {
            seedGatewayVersion = parseSeedManifest(data)
        } else {
            seedGatewayVersion = nil
        }
    }

    func inspect() async throws -> RuntimeInspection {
        let value = try await updater.run("inspect")
        guard let inspection = RuntimeInspection(value) else {
            throw RuntimeUpdaterError.invalidOutput("inspect envelope")
        }
        return inspection
    }

    func activateBundledSeed(currentVersionId: String?, blockers: [String]) async throws -> GatewayRuntimeChange {
        guard let seedRoot else { throw RuntimeUpdaterError.seedUnavailable }
        let staged = RuntimeOperationResult(try await updater.run("stage", arguments: ["--seed", seedRoot.path]))
        guard staged.ok, let versionId = staged.versionId else {
            return try await finish(.failed(staged.errorMessage ?? "runtime staging에 실패했습니다."))
        }
        if currentVersionId == versionId {
            return try await finish(.alreadyCurrent(versionId))
        }
        let activated = RuntimeOperationResult(try await updater.run(
            "activate", arguments: ["--version", versionId], blockers: blockers
        ))
        return try await finish(classify(activated, success: .activated(versionId)))
    }

    func rollback(blockers: [String]) async throws -> GatewayRuntimeChange {
        let result = RuntimeOperationResult(try await updater.run("rollback", blockers: blockers))
        return try await finish(classify(result, success: .rolledBack(result.versionId)))
    }

    private func classify(
        _ result: RuntimeOperationResult,
        success: GatewayRuntimeChangeOutcome
    ) -> GatewayRuntimeChangeOutcome {
        if result.ok { return success }
        if result.errorCode == "ACTIVATION_BLOCKED" || result.errorCode == "ROLLBACK_BLOCKED" { return .blocked }
        if result.errorCode == "NO_PREVIOUS_TARGET" { return .noPrevious }
        return .failed(result.errorMessage ?? "runtime 적용에 실패했습니다.")
    }

    private func finish(_ outcome: GatewayRuntimeChangeOutcome) async throws -> GatewayRuntimeChange {
        GatewayRuntimeChange(outcome: outcome, inspection: try await inspect())
    }
}
