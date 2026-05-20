import Foundation

public enum DakaFormatters {
    public static func shortTime(_ date: Date?) -> String {
        guard let date else {
            return "--:--"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else {
            return "0m"
        }

        let minutes = max(0, Int(seconds / 60))
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours == 0 {
            return "\(remainingMinutes)m"
        }

        return "\(hours)h\(String(format: "%02d", remainingMinutes))m"
    }

    public static func decimalHours(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds / 3600)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    public static func compactProgressBar(_ value: Double, segments: Int = 6) -> String {
        let clamped = min(1, max(0, value))
        let filled = Int((clamped * Double(segments)).rounded())
        let empty = max(0, segments - filled)
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: empty)
    }
}

public enum ProgressStage: String, Sendable {
    case empty
    case low
    case medium
    case high
    case complete

    public static func stage(spanSeconds: TimeInterval?, targetSeconds: TimeInterval) -> ProgressStage {
        guard let spanSeconds, targetSeconds > 0 else {
            return .empty
        }

        let progress = spanSeconds / targetSeconds
        if progress >= 1 {
            return .complete
        }
        if progress >= 0.75 {
            return .high
        }
        if progress >= 0.4 {
            return .medium
        }
        return .low
    }
}
