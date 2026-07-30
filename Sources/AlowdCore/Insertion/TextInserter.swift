import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
#endif

public protocol TextInserter: AnyObject, Sendable {
    func insert(_ text: String) throws
}

public enum TextInserterError: Error, LocalizedError, Equatable {
    case accessibilityNotGranted
    case secureInputActive
    case pasteEventCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "Alowd is missing Accessibility permission, so it could not paste the text."
        case .secureInputActive:
            "A secure input field (such as a password field) is active, so Alowd could not paste the text."
        case .pasteEventCreationFailed:
            "macOS refused to create the synthetic paste keystroke, so Alowd could not paste the text."
        }
    }
}

/// Undoes Alowd's last insertion by posting one Cmd+Z into the frontmost app.
///
/// Design tradeoff, chosen deliberately: the alternative — synthesizing N
/// backward-delete keystrokes matching the inserted text's length — is fragile,
/// because target apps may autocorrect, trim, or otherwise transform the pasted
/// text (so N is wrong), deletes land wherever the caret has since moved, and a
/// long transcript needs hundreds of events. A single Cmd+Z instead maps onto
/// the target app's own undo stack, which registers the paste as one undoable
/// action in effectively every macOS text view. Known limitation: if the user
/// typed after the insertion, Cmd+Z undoes their latest edit first — acceptable
/// for an explicit menu action the user invokes knowingly.
public enum UndoKeystrokeSender {
    public static func postUndo() throws {
        #if os(macOS)
        guard AXIsProcessTrusted() else {
            throw TextInserterError.accessibilityNotGranted
        }
        guard !IsSecureEventInputEnabled() else {
            throw TextInserterError.secureInputActive
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let zDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_Z), keyDown: true),
            let zUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_Z), keyDown: false)
        else {
            throw TextInserterError.pasteEventCreationFailed
        }
        zDown.flags = .maskCommand
        zUp.flags = .maskCommand
        zDown.post(tap: .cghidEventTap)
        zUp.post(tap: .cghidEventTap)
        #endif
    }
}

public final class ClipboardTextInserter: TextInserter {
    /// Convention from nspasteboard.org: well-behaved clipboard managers skip
    /// recording pasteboard entries marked with these types, so transcripts do
    /// not end up in third-party (possibly cloud-synced) clipboard histories.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// How long the transcript stays on the pasteboard for a manual Cmd+V when
    /// the synthetic paste could not be sent. Bounded so a failure never leaves
    /// the transcript on the shared pasteboard indefinitely.
    static let manualPasteWindow: TimeInterval = 60

    public init() {}

    public func insert(_ text: String) throws {
        #if os(macOS)
        // Secure input means a password prompt is focused somewhere; never
        // stage the transcript on the shared pasteboard at that moment. The
        // transcript is already saved to history before insertion is attempted.
        guard !IsSecureEventInputEnabled() else {
            throw TextInserterError.secureInputActive
        }

        let pasteboard = NSPasteboard.general
        // Deep-copy every previous item's raw data so images, files, and rich
        // text are restored intact — restoring only the plain string would
        // destroy them. Plain Data snapshots also cross the restore closure's
        // isolation boundary, which NSPasteboardItem cannot.
        let previousItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                copy[type] = item.data(forType: type)
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transientType)
        pasteboard.setData(Data(), forType: Self.concealedType)
        let insertedChangeCount = pasteboard.changeCount

        // Restores the previous clipboard unless the user copied something
        // else in the meantime (changeCount moved on).
        func scheduleRestore(after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount == insertedChangeCount else { return }
                pasteboard.clearContents()
                guard !previousItems.isEmpty else { return }
                pasteboard.writeObjects(previousItems.map { snapshot in
                    let item = NSPasteboardItem()
                    for (type, data) in snapshot {
                        item.setData(data, forType: type)
                    }
                    return item
                })
            }
        }

        // When the paste keystroke cannot be sent, the transcript stays
        // available for a manual Cmd+V — but only for a bounded window.
        guard AXIsProcessTrusted() else {
            scheduleRestore(after: Self.manualPasteWindow)
            throw TextInserterError.accessibilityNotGranted
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            scheduleRestore(after: Self.manualPasteWindow)
            throw TextInserterError.pasteEventCreationFailed
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)

        scheduleRestore(after: 0.5)
        #endif
    }
}
