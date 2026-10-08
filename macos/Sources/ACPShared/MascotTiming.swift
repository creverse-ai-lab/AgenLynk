import Foundation

/// One timing rule for every surface that shows an agent at rest (the notch,
/// its pill, the dashboard, the Pet): a turn that ended reads "완료" for this
/// long after its last activity, then "쉬는 중".
public enum MascotTiming {
    public static let finishedLinger: TimeInterval = 180

    /// Whether an agent at rest, last active at `updated`, still reads as
    /// just finished at `now`.
    public static func justFinished(updated: Date?, now: Date) -> Bool {
        guard let updated else { return false }
        return now.timeIntervalSince(updated) < finishedLinger
    }
}
