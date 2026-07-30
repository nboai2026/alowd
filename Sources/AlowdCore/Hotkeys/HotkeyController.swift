import Foundation
#if os(macOS)
import Carbon.HIToolbox
#endif

public enum HotkeyControllerError: Error, LocalizedError, Equatable {
    case registrationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            "Alowd could not register its global shortcut (macOS error \(status))."
        }
    }
}

/// Registers one macOS global hotkey. It does not create an event tap or monitor
/// keystrokes; macOS only notifies this process when the registered shortcut fires.
public final class HotkeyController: @unchecked Sendable {
    public struct Handlers {
        public var onToggle: () -> Void
        /// Push-to-talk: hotkey went down. Only fired while `pushToTalkEnabled`.
        public var onPress: () -> Void
        /// Push-to-talk: hotkey came back up. Only fired while `pushToTalkEnabled`.
        public var onRelease: () -> Void
        /// The dedicated cancel hotkey (Esc, registered only during recording) fired.
        public var onCancel: () -> Void

        public init(
            onToggle: @escaping () -> Void,
            onPress: @escaping () -> Void = {},
            onRelease: @escaping () -> Void = {},
            onCancel: @escaping () -> Void = {}
        ) {
            self.onToggle = onToggle
            self.onPress = onPress
            self.onRelease = onRelease
            self.onCancel = onCancel
        }
    }

    private let handlers: Handlers
    /// When true the hotkey behaves as hold-to-dictate: press fires onPress,
    /// release fires onRelease. When false (default) each press fires onToggle.
    public var pushToTalkEnabled = false
    #if os(macOS)
    private var eventHandler: EventHandlerRef?
    private var registeredHotkey: EventHotKeyRef?
    private var cancelHotkey: EventHotKeyRef?
    /// True between a hot key press and its release, so keyboard auto-repeat
    /// (repeated pressed events without a release) fires onToggle only once.
    private var awaitingRelease = false

    private static let signature: OSType = 0x41_4C_57_44 // "ALWD"
    private static let hotkeyIdentifier: UInt32 = 1
    private static let cancelHotkeyIdentifier: UInt32 = 2
    #endif

    public init(handlers: Handlers) {
        self.handlers = handlers
    }

    public func register(_ shortcut: DictationShortcut) throws {
        #if os(macOS)
        try installEventHandlerIfNeeded()

        // Register the new hotkey before unregistering the old one so a global
        // shortcut always remains active even if registration fails.
        let identifier = EventHotKeyID(signature: Self.signature, id: Self.hotkeyIdentifier)
        var newHotkey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &newHotkey
        )
        guard registerStatus == noErr, let newHotkey else {
            throw HotkeyControllerError.registrationFailed(registerStatus)
        }

        if let previous = registeredHotkey {
            UnregisterEventHotKey(previous)
        }
        registeredHotkey = newHotkey
        awaitingRelease = false
        #endif
    }

    /// Grabs the Esc key globally so a hot mic can always be cancelled.
    /// Because a Carbon hotkey steals the key from every app, this must be
    /// registered only while recording and released the moment recording ends.
    public func registerCancelHotkey() throws {
        #if os(macOS)
        guard cancelHotkey == nil else { return }
        try installEventHandlerIfNeeded()

        let identifier = EventHotKeyID(signature: Self.signature, id: Self.cancelHotkeyIdentifier)
        var newHotkey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            identifier,
            GetApplicationEventTarget(),
            0,
            &newHotkey
        )
        guard registerStatus == noErr, let newHotkey else {
            throw HotkeyControllerError.registrationFailed(registerStatus)
        }
        cancelHotkey = newHotkey
        #endif
    }

    public func unregisterCancelHotkey() {
        #if os(macOS)
        if let cancelHotkey {
            UnregisterEventHotKey(cancelHotkey)
            self.cancelHotkey = nil
        }
        #endif
    }

    public func unregister() {
        #if os(macOS)
        unregisterCancelHotkey()
        if let registeredHotkey {
            UnregisterEventHotKey(registeredHotkey)
            self.registeredHotkey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        awaitingRelease = false
        #endif
    }

    #if os(macOS)
    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.eventHandlerCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            throw HotkeyControllerError.registrationFailed(installStatus)
        }
    }
    #endif

    /// Allows a deterministic unit test without registering a process-wide hotkey.
    public func triggerForTesting() {
        handlers.onToggle()
    }

    /// Drives the press/release state machine exactly as a Carbon event would,
    /// including the auto-repeat guard, without registering a real hotkey.
    public func simulateHotkeyPressForTesting() {
        #if os(macOS)
        handleHotkeyPressed()
        #endif
    }

    public func simulateHotkeyReleaseForTesting() {
        #if os(macOS)
        handleHotkeyReleased()
        #endif
    }

    deinit {
        unregister()
    }

    #if os(macOS)
    private static let eventHandlerCallback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotkeyID = EventHotKeyID()
        let extractStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )
        guard
            extractStatus == noErr,
            hotkeyID.signature == HotkeyController.signature
        else {
            return OSStatus(eventNotHandledErr)
        }

        let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
        switch (hotkeyID.id, GetEventKind(event)) {
        case (HotkeyController.hotkeyIdentifier, UInt32(kEventHotKeyPressed)):
            controller.handleHotkeyPressed()
            return noErr
        case (HotkeyController.hotkeyIdentifier, UInt32(kEventHotKeyReleased)):
            controller.handleHotkeyReleased()
            return noErr
        case (HotkeyController.cancelHotkeyIdentifier, UInt32(kEventHotKeyPressed)):
            controller.runOnMain(.cancel)
            return noErr
        case (HotkeyController.cancelHotkeyIdentifier, UInt32(kEventHotKeyReleased)):
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }

    private func handleHotkeyPressed() {
        // Keyboard auto-repeat delivers repeated pressed events while the key
        // is held; only the first one before a release may fire.
        guard !awaitingRelease else { return }
        awaitingRelease = true
        if pushToTalkEnabled {
            runOnMain(.press)
        } else {
            runOnMain(.toggle)
        }
    }

    private func handleHotkeyReleased() {
        let wasHeld = awaitingRelease
        awaitingRelease = false
        if pushToTalkEnabled, wasHeld {
            runOnMain(.release)
        }
    }

    private enum HandlerKind: Sendable {
        case toggle, press, release, cancel
    }

    private func runOnMain(_ kind: HandlerKind) {
        if Thread.isMainThread {
            invoke(kind)
        } else {
            DispatchQueue.main.async {
                self.invoke(kind)
            }
        }
    }

    private func invoke(_ kind: HandlerKind) {
        switch kind {
        case .toggle: handlers.onToggle()
        case .press: handlers.onPress()
        case .release: handlers.onRelease()
        case .cancel: handlers.onCancel()
        }
    }
    #endif
}

#if os(macOS)
extension DictationShortcut {
    var keyCode: UInt32 {
        switch self {
        case .controlOptionSpace:
            UInt32(kVK_Space)
        case .controlOptionD:
            UInt32(kVK_ANSI_D)
        }
    }

    var carbonModifiers: UInt32 {
        UInt32(controlKey | optionKey)
    }
}
#endif
