import Foundation

public protocol TranscriptHistoryWriting: AnyObject, Sendable {
    func append(_ record: TranscriptRecord) throws
}

public final class HistoryStore: TranscriptHistoryWriting, @unchecked Sendable {
    private let historyURL: URL
    private let encoder = AlowdJSONCoding.makeEncoder()
    private let decoder = AlowdJSONCoding.makeDecoder()

    public init(root: URL) {
        self.historyURL = root.appendingPathComponent("data/history.json")
    }

    public func append(_ record: TranscriptRecord) throws {
        var records = try loadAll()
        records.append(record)
        try save(records)
    }

    public func loadAll() throws -> [TranscriptRecord] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        return try decoder.decode([TranscriptRecord].self, from: Data(contentsOf: historyURL))
    }

    public func delete(id: UUID) throws {
        var records = try loadAll()
        let removed = records.filter { $0.id == id }
        records.removeAll { $0.id == id }
        try save(records)
        removeRetainedAudio(for: removed)
    }

    public func deleteAll() throws {
        let records = try loadAll()
        try save([])
        removeRetainedAudio(for: records)
    }

    /// Deleting a record also deletes its retained audio, best effort.
    private func removeRetainedAudio(for records: [TranscriptRecord]) {
        for record in records {
            if let path = record.retainedAudioPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// Removes records older than the retention window (and their retained
    /// audio files, best effort). nil or non-positive retention keeps everything.
    /// Returns the number of records removed.
    @discardableResult
    public func prune(retentionDays: Int?, now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        guard
            let retentionDays,
            retentionDays > 0,
            let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now)
        else {
            return 0
        }

        let records = try loadAll()
        let kept = records.filter { $0.createdAt >= cutoff }
        let removed = records.filter { $0.createdAt < cutoff }
        guard !removed.isEmpty else { return 0 }

        try save(kept)
        for record in removed {
            if let audioPath = record.retainedAudioPath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
        }
        return removed.count
    }

    private func save(_ records: [TranscriptRecord]) throws {
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(records).write(to: historyURL, options: [.atomic])
    }
}
