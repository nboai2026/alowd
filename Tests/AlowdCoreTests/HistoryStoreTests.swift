import Foundation
import Testing
@testable import AlowdCore

struct HistoryStoreTests {
    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func historyDoesNotRequireRawAudioPath() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(root: root)
        let record = TranscriptRecord(mode: .myVoiceCasual, rawText: "um hi", finalText: "hi")
        try store.append(record)
        let loaded = try store.loadAll()

        #expect(loaded == [record], "History record must round trip")
        #expect(loaded.first?.retainedAudioPath == nil, "History must not require raw audio path")
    }

    @Test func audioDurationRoundTrips() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(root: root)
        let record = TranscriptRecord(mode: .raw, rawText: "hi", finalText: "hi", audioDurationSeconds: 2.5)
        try store.append(record)

        #expect(try store.loadAll().first?.audioDurationSeconds == 2.5)
    }

    @Test func deleteRemovesOnlyTheMatchingRecord() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(root: root)
        let first = TranscriptRecord(mode: .raw, rawText: "one", finalText: "one")
        let second = TranscriptRecord(mode: .raw, rawText: "two", finalText: "two")
        try store.append(first)
        try store.append(second)

        try store.delete(id: first.id)

        #expect(try store.loadAll() == [second], "Only the targeted record is removed")
    }

    @Test func deleteWithUnknownIDLeavesRecordsIntact() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(root: root)
        let record = TranscriptRecord(mode: .raw, rawText: "one", finalText: "one")
        try store.append(record)

        try store.delete(id: UUID())

        #expect(try store.loadAll() == [record])
    }

    @Test func deleteAllEmptiesTheHistory() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(root: root)
        try store.append(TranscriptRecord(mode: .raw, rawText: "one", finalText: "one"))
        try store.append(TranscriptRecord(mode: .raw, rawText: "two", finalText: "two"))

        try store.deleteAll()

        #expect(try store.loadAll().isEmpty)
        try store.append(TranscriptRecord(mode: .raw, rawText: "three", finalText: "three"))
        #expect(try store.loadAll().count == 1, "Store keeps working after delete all")
    }

    @Test func pruneRemovesOnlyRecordsOlderThanRetention() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(root: root)
        let now = Date()
        let old = TranscriptRecord(
            mode: .raw, rawText: "old", finalText: "old",
            createdAt: now.addingTimeInterval(-40 * 86_400)
        )
        let recent = TranscriptRecord(
            mode: .raw, rawText: "recent", finalText: "recent",
            createdAt: now.addingTimeInterval(-2 * 86_400)
        )
        try store.append(old)
        try store.append(recent)

        let removed = try store.prune(retentionDays: 30, now: now)
        #expect(removed == 1, "Exactly the one stale record must be pruned")
        #expect(try store.loadAll() == [recent], "Records inside the retention window must survive")
    }

    @Test func pruneWithNilRetentionKeepsEverything() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(root: root)
        let record = TranscriptRecord(
            mode: .raw, rawText: "ancient", finalText: "ancient",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try store.append(record)

        #expect(try store.prune(retentionDays: nil) == 0, "nil retention means keep forever")
        #expect(try store.prune(retentionDays: 0) == 0, "Non-positive retention must be a no-op")
        #expect(try store.loadAll() == [record], "Nothing may be deleted without a retention window")
    }

    @Test func pruneDeletesRetainedAudioOfPrunedRecords() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let audioURL = root.appendingPathComponent("stale.wav")
        try Data("wav".utf8).write(to: audioURL)

        let store = HistoryStore(root: root)
        try store.append(TranscriptRecord(
            mode: .raw, rawText: "old", finalText: "old",
            createdAt: Date().addingTimeInterval(-10 * 86_400),
            retainedAudioPath: audioURL.path
        ))

        _ = try store.prune(retentionDays: 7)
        #expect(
            !FileManager.default.fileExists(atPath: audioURL.path),
            "Pruning a record must also drop its retained audio file"
        )
    }

    @Test func deleteAllOnEmptyStoreSucceeds() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = HistoryStore(root: root)
        try store.deleteAll()
        #expect(try store.loadAll().isEmpty)
    }
}

struct HistoryStatsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Fixed "now": 2026-07-29 12:00:00 UTC.
    private var now: Date {
        date(year: 2026, month: 7, day: 29, hour: 12)
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func record(
        finalText: String,
        createdAt: Date,
        audioDurationSeconds: TimeInterval? = nil
    ) -> TranscriptRecord {
        TranscriptRecord(
            mode: .raw,
            rawText: finalText,
            finalText: finalText,
            createdAt: createdAt,
            audioDurationSeconds: audioDurationSeconds
        )
    }

    @Test func emptyHistoryProducesZeroedStats() {
        let stats = HistoryStats.compute(from: [], calendar: calendar, now: now)

        #expect(stats.totalDictations == 0)
        #expect(stats.totalWords == 0)
        #expect(stats.dictationsPerDay.isEmpty)
        #expect(stats.currentStreakDays == 0)
        #expect(stats.todayCount == 0)
        #expect(stats.averageWordsPerMinute == nil)
    }

    @Test func countsWordsAndDictationsPerDay() {
        let today = date(year: 2026, month: 7, day: 29)
        let yesterday = date(year: 2026, month: 7, day: 28)
        let stats = HistoryStats.compute(
            from: [
                record(finalText: "hello there world", createdAt: today),
                record(finalText: "  spaced   out\nwords ", createdAt: today),
                record(finalText: "one", createdAt: yesterday),
            ],
            calendar: calendar,
            now: now
        )

        #expect(stats.totalDictations == 3)
        #expect(stats.totalWords == 7, "3 + 3 + 1 words, whitespace-tolerant")
        #expect(stats.dictationsPerDay[calendar.startOfDay(for: today)] == 2)
        #expect(stats.dictationsPerDay[calendar.startOfDay(for: yesterday)] == 1)
        #expect(stats.todayCount == 2)
    }

    @Test func streakCountsConsecutiveDaysEndingToday() {
        let stats = HistoryStats.compute(
            from: [
                record(finalText: "a", createdAt: date(year: 2026, month: 7, day: 29)),
                record(finalText: "b", createdAt: date(year: 2026, month: 7, day: 28)),
                record(finalText: "c", createdAt: date(year: 2026, month: 7, day: 27)),
                // Gap on the 26th breaks the streak.
                record(finalText: "d", createdAt: date(year: 2026, month: 7, day: 25)),
            ],
            calendar: calendar,
            now: now
        )

        #expect(stats.currentStreakDays == 3)
    }

    @Test func streakSurvivesWhenTodayHasNoDictationYet() {
        let stats = HistoryStats.compute(
            from: [
                record(finalText: "a", createdAt: date(year: 2026, month: 7, day: 28)),
                record(finalText: "b", createdAt: date(year: 2026, month: 7, day: 27)),
            ],
            calendar: calendar,
            now: now
        )

        #expect(stats.currentStreakDays == 2, "Today is not over; yesterday's streak still counts")
        #expect(stats.todayCount == 0)
    }

    @Test func streakIsZeroAfterAMissedDay() {
        let stats = HistoryStats.compute(
            from: [record(finalText: "a", createdAt: date(year: 2026, month: 7, day: 27))],
            calendar: calendar,
            now: now
        )

        #expect(stats.currentStreakDays == 0, "Two days ago does not count as a live streak")
    }

    @Test func averageWPMUsesOnlyRecordsWithDuration() {
        let today = date(year: 2026, month: 7, day: 29)
        let stats = HistoryStats.compute(
            from: [
                // 10 words in 60 s -> 10 WPM.
                record(finalText: "w w w w w w w w w w", createdAt: today, audioDurationSeconds: 60),
                // 15 words in 30 s -> 30 WPM.
                record(
                    finalText: "w w w w w w w w w w w w w w w",
                    createdAt: today,
                    audioDurationSeconds: 30
                ),
                // No duration: excluded from WPM but counted in words.
                record(finalText: "no duration here", createdAt: today),
            ],
            calendar: calendar,
            now: now
        )

        #expect(stats.averageWordsPerMinute == 20, "(10 + 30) / 2")
        #expect(stats.totalWords == 28)
    }

    @Test func averageWPMIsNilWithoutDurationsOrWithBadDurations() {
        let today = date(year: 2026, month: 7, day: 29)
        let stats = HistoryStats.compute(
            from: [
                record(finalText: "hello world", createdAt: today),
                record(finalText: "zero duration", createdAt: today, audioDurationSeconds: 0),
            ],
            calendar: calendar,
            now: now
        )

        #expect(stats.averageWordsPerMinute == nil)
    }
}
