import Foundation

func formatLatency(_ milliseconds: Int) -> String {
    if milliseconds >= 1_000 {
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }
    return "\(milliseconds) ms"
}

func formatStatusLatency(_ milliseconds: Int) -> String {
    if milliseconds >= 10_000 { return ">9s" }
    return String(format: "%.1fs", Double(milliseconds) / 1_000)
}

func formatGaugeLatency(_ milliseconds: Int) -> String {
    if milliseconds >= 10_000 {
        return String(format: "%.0fs", Double(milliseconds) / 1_000)
    }
    if milliseconds >= 1_000 {
        return String(format: "%.1fs", Double(milliseconds) / 1_000)
    }
    return "\(milliseconds)ms"
}

func formatDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = max(Int(interval / 60), 0)
    if totalMinutes < 1 { return "<1m" }
    if totalMinutes < 60 { return "\(totalMinutes)m" }
    if totalMinutes < 1_440 {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h\(minutes)m"
    }
    let days = totalMinutes / 1_440
    let hours = (totalMinutes % 1_440) / 60
    return hours == 0 ? "\(days)d" : "\(days)d\(hours)h"
}
