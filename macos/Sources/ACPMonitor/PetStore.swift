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

    func start(executablePath: String, projection: PetActivityProjection, enabled: @escaping () -> Bool) {
        do {
            lastProjection = projection
            try controller.start(executablePath: executablePath, projection: projection) { [weak self] status in
                guard let self else { return }
                self.running = false
                if enabled() { self.error = "Pet이 종료되었습니다 (exit \(status))." }
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
