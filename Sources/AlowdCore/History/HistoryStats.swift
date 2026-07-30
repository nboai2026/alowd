import Foundation

/// Aggregate statistics over the dictation history, computed as a pure
/// function of the records so the math is directly testable.
public struct HistoryStats: Equatable, Sendable {
    public var totalDictations: Int
    /// Total words across all final texts.
    public var totalWords: Int
    /// Dictation counts keyed by the start of the day the dictation happened.
    public var dictationsPerDay: [Date: Int]
    /// Consecutive days with at least one dictation, ending today. A streak is
    /// still alive when today has no dictation yet (the day is not over), in
    /// which case counting starts from yesterday.
    public var currentStreakDays: Int
    public var todayCount: Int
    /// Mean words-per-minute over records that carry an audio duration.
    /// `nil` when no record has a usable duration.
    public var averageWordsPerMinute: Double?

    public init(
        totalDictations: Int,
        totalWords: Int,
        dictationsPerDay: [Date: Int],
        currentStreakDays: Int,
        todayCount: Int,
        averageWordsPerMinute: Double?
    ) {
        self.totalDictations = totalDictations
        self.totalWords = totalWords
        self.dictationsPerDay = dictationsPerDay
        self.currentStreakDays = currentStreakDays
        self.todayCount = todayCount
        self.averageWordsPerMinute = averageWordsPerMinute
    }

    public static func compute(
        from records: [TranscriptRecord],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> HistoryStats {
        var dictationsPerDay: [Date: Int] = [:]
        var totalWords = 0
        var wordsPerMinuteSamples: [Double] = []

        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            dictationsPerDay[day, default: 0] += 1

            let words = wordCount(of: record.finalText)
            totalWords += words

            if let duration = record.audioDurationSeconds, duration > 0, words > 0 {
                wordsPerMinuteSamples.append(Double(words) / (duration / 60))
            }
        }

        let today = calendar.startOfDay(for: now)
        var streak = 0
        var cursor = today
        if dictationsPerDay[cursor] == nil {
            // Today is not over yet; a streak ending yesterday is still alive.
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while dictationsPerDay[cursor] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        let averageWPM = wordsPerMinuteSamples.isEmpty
            ? nil
            : wordsPerMinuteSamples.reduce(0, +) / Double(wordsPerMinuteSamples.count)

        return HistoryStats(
            totalDictations: records.count,
            totalWords: totalWords,
            dictationsPerDay: dictationsPerDay,
            currentStreakDays: streak,
            todayCount: dictationsPerDay[today] ?? 0,
            averageWordsPerMinute: averageWPM
        )
    }

    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
