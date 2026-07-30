import SwiftUI
import AppKit
import AlowdCore

/// Menu-bar entry point for the History window. Lives in its own view so it
/// can use the `openWindow` environment action.
struct HistoryMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("History...") {
            openWindow(id: HistoryWindowID.value)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

enum HistoryWindowID {
    static let value = "history"
}

extension Notification.Name {
    /// Posted after a dictation is recorded so an open History window
    /// refreshes without being closed and reopened.
    static let alowdHistoryChanged = Notification.Name("AlowdHistoryChanged")
}

@MainActor
final class HistoryWindowModel: ObservableObject {
    @Published var searchText = ""
    @Published private(set) var records: [TranscriptRecord] = []
    @Published private(set) var stats = HistoryStats.compute(from: [])
    @Published var errorMessage: String?
    @Published var isConfirmingDeleteAll = false

    private let store: HistoryStore
    // nonisolated(unsafe): only written once in init and read in deinit, so
    // there is no concurrent access; this lets the nonisolated deinit remove
    // the observer under Swift 6 isolation checking.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(store: HistoryStore) {
        self.store = store
        observer = NotificationCenter.default.addObserver(
            forName: .alowdHistoryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    convenience init() {
        self.init(store: HistoryStore(root: ProfileStore().root))
    }

    func reload() {
        do {
            records = try store.loadAll().sorted { $0.createdAt > $1.createdAt }
            stats = HistoryStats.compute(from: records)
            errorMessage = nil
        } catch {
            records = []
            stats = HistoryStats.compute(from: [])
            errorMessage = "Could not load history: \(error.localizedDescription)"
        }
    }

    /// Records grouped by day (newest day first, newest record first inside a
    /// day), filtered by the search text over both raw and final text.
    var sections: [(day: Date, records: [TranscriptRecord])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? records
            : records.filter {
                $0.finalText.localizedCaseInsensitiveContains(query)
                    || $0.rawText.localizedCaseInsensitiveContains(query)
            }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { (day: $0, records: grouped[$0] ?? []) }
    }

    func copyFinalText(_ record: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.finalText, forType: .string)
    }

    func delete(_ record: TranscriptRecord) {
        do {
            try store.delete(id: record.id)
            reload()
        } catch {
            errorMessage = "Could not delete the dictation: \(error.localizedDescription)"
        }
    }

    func deleteAll() {
        do {
            try store.deleteAll()
            reload()
        } catch {
            errorMessage = "Could not delete history: \(error.localizedDescription)"
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HistoryStatsHeader(stats: model.stats)
                .padding()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search dictations", text: $model.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 8)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if model.sections.isEmpty {
                Spacer()
                Text(model.searchText.isEmpty ? "No dictations yet." : "No dictations match the search.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(model.sections, id: \.day) { section in
                        Section(Self.dayFormatter.string(from: section.day)) {
                            ForEach(section.records) { record in
                                HistoryRow(
                                    record: record,
                                    onCopy: { model.copyFinalText(record) },
                                    onDelete: { model.delete(record) }
                                )
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    model.isConfirmingDeleteAll = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                }
                .disabled(model.records.isEmpty)
            }
        }
        .confirmationDialog(
            "Delete all dictation history?",
            isPresented: $model.isConfirmingDeleteAll
        ) {
            Button("Delete All", role: .destructive) {
                model.deleteAll()
            }
        } message: {
            Text("This removes every recorded dictation. This cannot be undone.")
        }
        .onAppear {
            model.reload()
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

private struct HistoryStatsHeader: View {
    let stats: HistoryStats

    var body: some View {
        HStack(spacing: 12) {
            HistoryStatTile(value: "\(stats.totalWords)", label: "Words dictated")
            HistoryStatTile(
                value: "\(stats.currentStreakDays) day\(stats.currentStreakDays == 1 ? "" : "s")",
                label: "Streak"
            )
            HistoryStatTile(value: "\(stats.todayCount)", label: "Today")
            if let wpm = stats.averageWordsPerMinute {
                HistoryStatTile(value: "\(Int(wpm.rounded()))", label: "Avg WPM")
            }
        }
    }
}

private struct HistoryStatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.finalText)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text(Self.timeFormatter.string(from: record.createdAt))
                    if let bundleID = record.appBundleIdentifier {
                        Text(bundleID)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy final text")
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this dictation")
        }
        .padding(.vertical, 4)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
