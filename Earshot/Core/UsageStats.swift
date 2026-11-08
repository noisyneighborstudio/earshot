import Foundation

/// Numbers for Home, computed from local history and meetings (nothing is tracked elsewhere).
struct UsageStats: Equatable, Sendable {
    var wordsDictatedToday = 0
    /// Typing time those words would have taken at `typingWordsPerMinute`.
    var typingMinutesSavedToday = 0
    var meetingsToday = 0
    var meetingMinutesToday = 0
    var meetingsNeedingNotes = 0
    var openActionItems = 0
    var myOpenActionItems = 0

    static let typingWordsPerMinute = 40.0

    static func compute(
        history: [HistoryEntry], meetings: [Meeting], now: Date = .now, calendar: Calendar = .current
    ) -> UsageStats {
        var stats = UsageStats()
        for entry in history where calendar.isDate(entry.date, inSameDayAs: now) && entry.error == nil {
            stats.wordsDictatedToday += (entry.text ?? entry.raw).split(whereSeparator: \.isWhitespace).count
        }
        stats.typingMinutesSavedToday = Int((Double(stats.wordsDictatedToday) / typingWordsPerMinute).rounded())
        for meeting in meetings {
            if calendar.isDate(meeting.startedAt, inSameDayAs: now) {
                stats.meetingsToday += 1
                stats.meetingMinutesToday += Int(((meeting.duration ?? 0) / 60).rounded())
            }
            if meeting.needsNotes && !meeting.lines.isEmpty { stats.meetingsNeedingNotes += 1 }
            for item in meeting.actionItems where !item.done {
                stats.openActionItems += 1
                if item.isMine { stats.myOpenActionItems += 1 }
            }
        }
        return stats
    }
}
