import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import AlowdCore

extension Notification.Name {
    /// Posted whenever dictionary suggestions change on disk so the menu
    /// badge can refresh.
    static let alowdDictionarySuggestionsChanged = Notification.Name("AlowdDictionarySuggestionsChanged")
}

/// Replicates Wispr Flow's auto-learning loop: after a successful insertion,
/// wait a bit, re-read the frontmost app's focused text field through the
/// Accessibility API, diff it against what was inserted, and queue learned
/// terms as pending suggestions. Everything is best effort — an unreadable
/// field simply learns nothing.
@MainActor
final class AutoLearnController: ObservableObject {
    @Published private(set) var pendingCount = 0

    private let store: DictionaryStore
    private let delay: Duration
    private var learningTask: Task<Void, Never>?
    // The controller lives for the app's lifetime, so the block observer is
    // registered once and never removed.
    private var observer: NSObjectProtocol?

    init(store: DictionaryStore, delay: Duration = .seconds(10)) {
        self.store = store
        self.delay = delay
        refreshPendingCount()
        observer = NotificationCenter.default.addObserver(
            forName: .alowdDictionarySuggestionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPendingCount()
            }
        }
    }

    func refreshPendingCount() {
        pendingCount = (try? store.loadSuggestions().count) ?? 0
    }

    /// Schedules a single delayed re-read of the focused field. A new
    /// dictation (or cancel) replaces/cancels the pending read.
    func scheduleLearning(insertedText: String) {
        learningTask?.cancel()
        let delay = delay
        // Remember where we pasted: a delayed read must never pick up text from
        // an app the user switched to in the meantime.
        let originApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        learningTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.performLearning(insertedText: insertedText, originApp: originApp)
        }
    }

    func cancelScheduledLearning() {
        learningTask?.cancel()
        learningTask = nil
    }

    private func performLearning(insertedText: String, originApp: String?) {
        // Same app we pasted into, or we do not look at all.
        guard let originApp,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == originApp
        else { return }
        // Never read while the system is in secure input (password entry).
        guard !IsSecureEventInputEnabled() else { return }
        guard let fieldText = Self.focusedFieldValue(), !fieldText.isEmpty else { return }
        // Only learn from a field that still shows our own insertion.
        guard LearningAnchor.fieldPlausiblyContainsInsertion(
            insertedText: insertedText,
            fieldText: fieldText
        ) else { return }
        let existingTerms = (try? store.loadTerms()) ?? []
        let suggestions = CorrectionLearner(existingTerms: existingTerms)
            .learn(insertedText: insertedText, currentFieldText: fieldText)
        guard !suggestions.isEmpty else { return }
        if (try? store.appendSuggestions(suggestions)) ?? 0 > 0 {
            refreshPendingCount()
        }
    }

    /// Reads the focused UI element's text value via Accessibility. Returns
    /// nil (silently) when there is no focused element, it has no string
    /// value, or the permission is missing.
    private static func focusedFieldValue() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            ) == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }

        let element = focusedRef as! AXUIElement

        // Secure text fields (password inputs) are never read.
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }

        var valueRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
            let value = valueRef as? String
        else { return nil }
        return value
    }
}
