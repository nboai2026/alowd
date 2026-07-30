import SwiftUI
import AppKit
import AlowdCore

/// What the floating dictation pill is currently showing. Driven by
/// DictationMenuModel alongside its existing state machine; `hidden` means the
/// panel is off screen.
enum OverlayPhase: Equatable {
    case hidden
    case recording
    case transcribing
    /// Insertion succeeded; associated value is the inserted text.
    case done(String)
    /// The user cancelled; shown briefly, then hidden.
    case cancelled
    /// Dictation failed; associated value is a short user-facing message
    /// (for example the clipboard-fallback notice).
    case error(String)

    /// Terminal phases linger ~1.5s and then the panel hides itself.
    var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .error:
            true
        case .hidden, .recording, .transcribing:
            false
        }
    }
}

/// Owns the borderless floating NSPanel that shows the Wispr-style dictation
/// pill. Observes the menu model's published overlay phase and the
/// "Show dictation overlay" setting; when the setting is off the panel never
/// appears.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private weak var model: DictationMenuModel?
    private var phaseTask: Task<Void, Never>?
    private var settingTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    /// How long terminal states (inserted snippet, cancel, error) stay visible.
    static let terminalLingerSeconds: TimeInterval = 1.5
    private static let panelSize = NSSize(width: 440, height: 104)
    /// Distance from the bottom of the visible screen area to the panel.
    private static let bottomMargin: CGFloat = 72

    init(model: DictationMenuModel) {
        self.model = model

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        // The pill itself ignores clicks (allowsHitTesting(false) in the view)
        // except for the small cancel button, and the panel never activates,
        // so it does not steal focus from the app being dictated into.
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        self.panel = panel

        // Republish the model's phase / setting changes into show-hide calls.
        // Combine-free: two lightweight observation loops over published values.
        phaseTask = Task { [weak self] in
            guard let values = self?.model?.$overlayPhase.values else { return }
            for await phase in values {
                self?.apply(phase: phase)
            }
        }
        settingTask = Task { [weak self] in
            guard let values = self?.model?.$showOverlay.values else { return }
            for await enabled in values where !enabled {
                self?.hideNow()
            }
        }
    }

    deinit {
        phaseTask?.cancel()
        settingTask?.cancel()
        hideTask?.cancel()
    }

    private func apply(phase: OverlayPhase) {
        guard model?.showOverlay ?? false else {
            hideNow()
            return
        }

        switch phase {
        case .hidden:
            hideNow()
        case .recording, .transcribing:
            hideTask?.cancel()
            hideTask = nil
            show()
        case .done, .cancelled, .error:
            show()
            scheduleHide()
        }
    }

    private func show() {
        positionOnActiveScreen()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func hideNow() {
        hideTask?.cancel()
        hideTask = nil
        panel.orderOut(nil)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.terminalLingerSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
            self?.hideTask = nil
        }
    }

    /// Centers the pill near the bottom of the screen the user is working on
    /// (the one with the key window, falling back to the first screen).
    private func positionOnActiveScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.bottomMargin
        ))
    }
}

// MARK: - Views

/// The pill content. Everything except the cancel button is click-inert.
struct OverlayView: View {
    @ObservedObject var model: DictationMenuModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var pill: some View {
        HStack(spacing: 12) {
            content
            if showsCancelButton {
                cancelButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .allowsHitTesting(false)
        )
        .frame(maxWidth: 420)
    }

    private var showsCancelButton: Bool {
        switch model.overlayPhase {
        case .recording, .transcribing:
            true
        case .hidden, .done, .cancelled, .error:
            false
        }
    }

    private var cancelButton: some View {
        Button {
            model.cancelRecording()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Cancel dictation (Esc)")
    }

    @ViewBuilder
    private var content: some View {
        switch model.overlayPhase {
        case .hidden:
            EmptyView()
        case .recording:
            recordingContent
        case .transcribing:
            transcribingContent
        case .done(let text):
            doneContent(text)
        case .cancelled:
            statusRow(icon: "xmark.circle", tint: .white.opacity(0.7), text: "Cancelled")
        case .error(let message):
            statusRow(icon: "exclamationmark.triangle.fill", tint: .orange, text: message)
        }
    }

    private var recordingContent: some View {
        HStack(spacing: 12) {
            LevelBarsView(level: model.inputLevel)
            VStack(alignment: .leading, spacing: 2) {
                if model.livePartialTranscript.isEmpty {
                    Text("Listening…")
                        .font(.callout)
                        .foregroundStyle(.white)
                } else {
                    Text(model.livePartialTranscript)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(recordingHint)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .allowsHitTesting(false)
    }

    private var recordingHint: String {
        model.hotkeyMode == .pushToTalk
            ? "Release \(model.selectedShortcut.displayName) to insert · Esc to cancel"
            : "\(model.selectedShortcut.displayName) to insert · Esc to cancel"
    }

    private var transcribingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribing…")
                    .font(.callout)
                    .foregroundStyle(.white)
                if !model.livePartialTranscript.isEmpty {
                    Text(model.livePartialTranscript)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func doneContent(_ text: String) -> some View {
        statusRow(
            icon: "checkmark.circle.fill",
            tint: .green,
            text: text.isEmpty ? "Nothing to insert" : String(text.prefix(120))
        )
    }

    private func statusRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
        .allowsHitTesting(false)
    }
}

/// Scrolling waveform-style level bars fed by the recorder's RMS stream.
struct LevelBarsView: View {
    var level: Float

    private static let barCount = 18
    @State private var history: [Float] = Array(repeating: 0, count: barCount)

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2.5, height: barHeight(history[index]))
            }
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.1), value: history)
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(newLevel)
        }
    }

    /// Speech RMS on a 16-bit mic tap typically peaks well under 0.5, so
    /// scale up before clamping to keep the bars lively.
    private func barHeight(_ value: Float) -> CGFloat {
        let normalized = min(1, CGFloat(value) * 5)
        return 4 + normalized * 24
    }
}
