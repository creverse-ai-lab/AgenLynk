import Foundation

// How long ago / how long for, in the dashboard's words. One file so every
// surface (menu bar, inspector, settings) phrases time the same way.

/// "방금", "12초 전", "3분 전", "2시간 전", "4일 전".
func relativeTimeText(from date: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date).rounded())
    if seconds < 3 { return "방금" }
    if seconds < 60 { return "\(seconds)초 전" }
    if seconds < 3_600 { return "\(seconds / 60)분 전" }
    if seconds < 86_400 { return "\(seconds / 3_600)시간 전" }
    return "\(seconds / 86_400)일 전"
}

/// "3분째", "1시간 5분째" for a running turn.
func elapsedText(from start: Date, to now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
    if minutes < 1 { return "방금 시작" }
    if minutes < 60 { return "\(minutes)분째" }
    return "\(minutes / 60)시간 \(minutes % 60)분째"
}
