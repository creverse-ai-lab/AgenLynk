import Foundation

// The single ISO8601 reader/writer for everything Lynk exchanges: Monitor
// snapshots, and the pet-state/pet-actions contract the Pet reads.
//
// Lynk always *writes* fractional seconds, and a default ISO8601DateFormatter
// rejects fractional input outright. The Pet used to carry its own copy of this
// pair and shipped without the fractional formatter, so every contract
// timestamp parsed to nil and all its time-based behaviour (offline fade, ready
// linger, flowing arrows) was silently dead. One definition, both sides.

private let fractionalISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let standardISO8601Formatter = ISO8601DateFormatter()

/// Accepts both the fractional form Lynk writes and plain internet date-time.
public func parseTimestamp(_ value: String) -> Date? {
    fractionalISO8601Formatter.date(from: value) ?? standardISO8601Formatter.date(from: value)
}

public func monitorTimestamp(_ date: Date) -> String {
    fractionalISO8601Formatter.string(from: date)
}
