import Combine
import Foundation

@MainActor
final class PetStore: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var error: String?

    private let controller: PetController
    private var lastProjection: PetActivityProjection?

    init(controller: PetController? = nil) {
        self.controller = controller ?? PetController()
    }

    func start(executablePath: String, projection: PetActivityProjection, style: PetStyle = .orbit, enabled: @escaping () -> Bool) {
        start(executablePath: executablePath, projection: projection, style: style, enabled: enabled, retryingLock: false)
    }

    private func start(executablePath: String, projection: PetActivityProjection, style: PetStyle,
                       enabled: @escaping () -> Bool, retryingLock: Bool) {
        do {
            lastProjection = projection
            try controller.start(executablePath: executablePath, projection: projection, style: style) { [weak self] exit in
                guard let self else { return }
                self.running = false
                guard enabled() else { return }
                switch exit {
                case .lockHeld where !retryingLock:
                    // Another Pet held the lock while it was being ended (an
                    // orphan the start just signalled): once more.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard let self, enabled(), !self.running else { return }
                        self.start(executablePath: executablePath, projection: self.lastProjection ?? projection,
                                   style: style, enabled: enabled, retryingLock: true)
                    }
                case .lockHeld:
                    self.error = "다른 Pet이 이미 실행 중이라 새 Pet을 띄우지 못했습니다. AgenLynk가 두 개 실행 중이면 하나만 남기세요."
                case let .crashed(signal):
                    self.error = "Pet이 비정상 종료되었습니다 (signal \(signal)). ~/Library/Application Support/ACPMonitor/pet.log와 크래시 리포트를 확인하세요."
                case let .exited(status):
                    self.error = "Pet이 종료되었습니다 (exit \(status))."
                }
            }
            running = true
            error = nil
        } catch {
            running = false
            self.error = error.localizedDescription
        }
    }

    func sync(projection: PetActivityProjection, enabled: Bool) {
        guard enabled, running, projection != lastProjection else { return }
        lastProjection = projection
        // The two atomic file writes run off the main actor, in order.
        controller.scheduleUpdate(projection) { [weak self] failure in
            guard let self else { return }
            // A failed write is retried with the next sync, not skipped as unchanged.
            if failure != nil { self.lastProjection = nil }
            let message = failure.map { "Pet 상태 공유 실패: \($0.localizedDescription)" }
            if self.error != message { self.error = message }
        }
    }

    func stop() {
        controller.stop()
        running = false
        error = nil
        lastProjection = nil
    }
}
