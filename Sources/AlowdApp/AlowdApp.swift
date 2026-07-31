import SwiftUI
import AppKit
import ApplicationServices
import AVFoundation
import AlowdCore

@main
struct AlowdApp: App {
    @StateObject private var model = DictationMenuModel()
    @StateObject private var historyModel = HistoryWindowModel()
    @StateObject private var dictionaryModel = DictionaryWindowModel()
    @StateObject private var settingsModel = SettingsWindowModel()

    var body: some Scene {
        MenuBarExtra("Alowd", systemImage: model.menuBarIconName) {
            Text("Alowd")
            Text(model.profileRoot.path)
            Divider()

            Picker("Mode", selection: Binding(
                get: { model.selectedMode },
                set: { model.selectMode($0) }
            )) {
                ForEach(WritingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Picker("Shortcut", selection: Binding(
                get: { model.selectedShortcut },
                set: { model.selectShortcut($0) }
            )) {
                ForEach(DictationShortcut.allCases, id: \.self) { shortcut in
                    Text(shortcut.displayName).tag(shortcut)
                }
            }
            Picker("Trigger", selection: Binding(
                get: { model.hotkeyMode },
                set: { model.selectHotkeyMode($0) }
            )) {
                Text("Press to start/stop").tag(HotkeyMode.toggle)
                Text("Hold to dictate").tag(HotkeyMode.pushToTalk)
            }
            Text(model.hotkeyMode == .pushToTalk
                 ? "Hold \(model.selectedShortcut.displayName) while speaking"
                 : "\(model.selectedShortcut.displayName) starts and stops")
                .foregroundStyle(.secondary)

            Divider()
            Toggle("Translation to English", isOn: Binding(
                get: { model.translateToEnglish },
                set: { model.setTranslateToEnglish($0) }
            ))
            Picker("Language", selection: Binding(
                get: { model.selectedLanguage },
                set: { model.selectLanguage($0) }
            )) {
                ForEach(SpokenLanguage.supported) { language in
                    Text(language.displayName).tag(language.code)
                }
            }

            Divider()
            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                if model.isRecording {
                    model.stopRecording()
                } else {
                    model.startRecording()
                }
            }
            .disabled(model.isBusy || model.isStarting)

            Button("Cancel Recording") {
                model.cancelRecording()
            }
            .disabled(!model.isRecording && !model.isBusy)

            Button("Undo Last Insertion") {
                model.undoLastInsertion()
            }
            .disabled(!model.canUndoLastInsertion)

            Divider()
            HistoryMenuItem()
            DictionaryMenuItem(autoLearn: model.autoLearn)
            SettingsMenuItem()

            Divider()
            Text(model.statusMessage)
            Text(model.modelStatusMessage)
                .foregroundStyle(model.isModelReady ? Color.secondary : Color.orange)
            Button(model.isInstallingModel ? model.modelInstallButtonTitle : "Install Recommended WhisperKit Model") {
                model.installRecommendedModel()
            }
            .disabled(model.isInstallingModel || model.isBusy || model.isRecording || model.isModelReady)
            Button("Check WhisperKit Model") {
                model.refreshModelStatus()
            }
            .disabled(model.isInstallingModel)
            Button("Open Settings Folder") {
                NSWorkspace.shared.open(model.profileRoot)
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }

        Window("History", id: HistoryWindowID.value) {
            HistoryView(model: historyModel)
        }
        .defaultSize(width: 640, height: 520)

        Window("Dictionary", id: DictionaryWindowID.value) {
            DictionaryView(model: dictionaryModel)
        }
        .defaultSize(width: 620, height: 500)

        Window("Settings", id: SettingsWindowID.value) {
            SettingsView(model: settingsModel)
        }
        .defaultSize(width: 560, height: 640)
    }
}

@MainActor
final class DictationMenuModel: ObservableObject {
    @Published var selectedMode: WritingMode = AppSettings.default.defaultMode
    @Published var selectedShortcut: DictationShortcut = AppSettings.default.dictationShortcut
    @Published var selectedLanguage: String? = AppSettings.default.language
    @Published var translateToEnglish: Bool = AppSettings.default.translateToEnglish
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var isStarting = false
    @Published var statusMessage = "Ready"
    @Published var modelStatusMessage = "Checking local WhisperKit model..."
    @Published var isModelReady = false
    @Published var isInstallingModel = false
    @Published var modelInstallProgress: Double?

    @Published private(set) var hotkeyMode: HotkeyMode = AppSettings.default.hotkeyMode
    /// Set after each successful insertion so "Undo Last Insertion" can enable.
    @Published private(set) var canUndoLastInsertion = false
    private var modelVariant = AppSettings.default.modelVariant

    /// Latest live partial transcript (display-only; batch result wins).
    @Published private(set) var livePartialTranscript = ""
    /// Live microphone RMS level for a level/waveform indicator.
    @Published private(set) var inputLevel: Float = 0
    /// What the floating dictation pill shows; `hidden` keeps it off screen.
    @Published private(set) var overlayPhase: OverlayPhase = .hidden
    /// Mirrors AppSettings.showOverlay; the overlay never appears when false.
    @Published private(set) var showOverlay = AppSettings.default.showOverlay
    /// Owns the floating pill panel; created once the model is fully set up.
    private var overlayController: OverlayController?

    private let profileStore: ProfileStore
    private let recorder: StreamingAudioRecorder
    private let historyStore: HistoryStore
    private let runner: DictationSessionRunner
    /// Cache for the live path's own engine, used only until the runner has a
    /// cached pipeline whose engine can be shared.
    private var cachedLiveEngine: (key: LiveEngineCacheKey, engine: any LiveSampleTranscribing)?
    private var levelTask: Task<Void, Never>?
    /// Owns the delayed post-insertion field re-read + suggestion queueing;
    /// also exposes the pending-suggestions badge count for the menu.
    let autoLearn: AutoLearnController
    private var stopTask: Task<Void, Never>?
    /// Push-to-talk: the key came back up while the start Task was still
    /// running, so stop as soon as recording is actually live.
    private var pushToTalkStopRequested = false
    private var settingsObserver: NSObjectProtocol?
    private lazy var hotkeyController = HotkeyController(handlers: .init(
        onToggle: { [weak self] in
            self?.toggleRecordingFromShortcut()
        },
        onPress: { [weak self] in
            self?.pushToTalkPressed()
        },
        onRelease: { [weak self] in
            self?.pushToTalkReleased()
        },
        onCancel: { [weak self] in
            self?.cancelRecording()
        }
    ))

    init() {
        let profileStore = ProfileStore()
        let recorder = StreamingAudioRecorder()
        let historyStore = HistoryStore(root: profileStore.root)
        self.profileStore = profileStore
        self.recorder = recorder
        self.historyStore = historyStore
        self.runner = DictationSessionRunner(
            recorder: recorder,
            profile: profileStore,
            history: historyStore,
            pipelineFactory: Self.makePipeline(settings:)
        )
        // A tap of the shortcut (easy to do in push-to-talk) should read as
        // "never mind", not as a failed transcription of a header-only WAV.
        self.runner.minimumRecordingDuration = 0.4
        self.autoLearn = AutoLearnController(store: DictionaryStore(root: profileStore.root))
        // Live partials are best effort and display-only; the runner starts
        // and stops this alongside the recording it already owns.
        runner.liveTranscription = LiveTranscriptionController(
            source: recorder,
            engineProvider: { [weak self] in
                guard let self else { throw AlowdAppError("Alowd is shutting down.") }
                return try await self.liveTranscriptionEngine()
            }
        )
        runner.onPartialTranscript = { [weak self] partial in
            guard let self, self.isRecording else { return }
            self.livePartialTranscript = partial
            self.statusMessage = "… " + String(partial.suffix(80))
        }
        loadProfile()
        pruneHistoryOnLaunch()
        overlayController = OverlayController(model: self)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .alowdSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadSettingsFromDisk()
            }
        }
    }

    func selectMode(_ mode: WritingMode) {
        selectedMode = mode
        do {
            try profileStore.bootstrap()
            var settings = try profileStore.loadSettings()
            settings.defaultMode = mode
            try profileStore.saveSettings(settings)
            statusMessage = "Mode: \(mode.displayName)"
        } catch {
            statusMessage = "Mode changed for this run. Could not save settings: \(error.localizedDescription)"
        }
    }

    func selectShortcut(_ shortcut: DictationShortcut) {
        guard shortcut != selectedShortcut else { return }

        do {
            try hotkeyController.register(shortcut)
            selectedShortcut = shortcut
            try profileStore.bootstrap()
            var settings = try profileStore.loadSettings()
            settings.dictationShortcut = shortcut
            try profileStore.saveSettings(settings)
            statusMessage = "Shortcut: \(shortcut.displayName)"
        } catch {
            statusMessage = "Could not use \(shortcut.displayName): \(error.localizedDescription)"
        }
    }

    func selectLanguage(_ language: String?) {
        selectedLanguage = language
        do {
            try profileStore.bootstrap()
            var settings = try profileStore.loadSettings()
            settings.language = language
            try profileStore.saveSettings(settings)
            statusMessage = "Language: \(language ?? "Auto")"
        } catch {
            statusMessage = "Language changed for this run. Could not save settings: \(error.localizedDescription)"
        }
    }

    func selectHotkeyMode(_ mode: HotkeyMode) {
        hotkeyMode = mode
        hotkeyController.pushToTalkEnabled = mode == .pushToTalk
        do {
            try profileStore.bootstrap()
            var settings = try profileStore.loadSettings()
            settings.hotkeyMode = mode
            try profileStore.saveSettings(settings)
        } catch {
            statusMessage = "Hotkey mode changed for this run. Could not save settings: \(error.localizedDescription)"
            return
        }
        statusMessage = mode == .pushToTalk
            ? "Hold \(selectedShortcut.displayName) to dictate."
            : "\(selectedShortcut.displayName) starts and stops dictation."
    }

    func setTranslateToEnglish(_ enabled: Bool) {
        translateToEnglish = enabled
        do {
            try profileStore.bootstrap()
            var settings = try profileStore.loadSettings()
            settings.translateToEnglish = enabled
            try profileStore.saveSettings(settings)
            statusMessage = enabled ? "Translation to English on." : "Translation to English off."
        } catch {
            statusMessage = "Translation changed for this run. Could not save settings: \(error.localizedDescription)"
        }
    }

    private func toggleRecordingFromShortcut() {
        guard !isBusy else {
            statusMessage = "Still transcribing..."
            return
        }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    // MARK: - Push to talk

    private func pushToTalkPressed() {
        guard !isBusy else {
            statusMessage = "Still transcribing..."
            return
        }
        pushToTalkStopRequested = false
        startRecording()
    }

    private func pushToTalkReleased() {
        if isRecording {
            stopRecording()
        } else if isStarting {
            // The key came up before the async start finished; finish the
            // start, then stop immediately so no hot mic is left running.
            pushToTalkStopRequested = true
        }
    }

    /// Mirrors the runner's state machine into the published UI properties.
    private func syncStateFromRunner() {
        isRecording = runner.state == .recording
        isBusy = runner.state == .transcribing
    }

    func startRecording() {
        // Synchronous MainActor guard: a second trigger while a start Task is
        // pending (or a session is active) must be ignored.
        guard !isRecording, !isBusy, !isStarting else { return }
        isStarting = true
        // A new dictation supersedes any pending post-insertion field re-read.
        autoLearn.cancelScheduledLearning()

        Task {
            defer {
                isStarting = false
                syncStateFromRunner()
                if pushToTalkStopRequested {
                    pushToTalkStopRequested = false
                    if isRecording {
                        stopRecording()
                    }
                }
            }

            guard requestAccessibilityAccessIfNeeded() else {
                statusMessage = "Accessibility permission is required so Alowd can paste into the active field."
                return
            }

            guard await requestMicrophoneAccessIfNeeded() else {
                statusMessage = "Microphone permission is required before Alowd can record."
                return
            }

            do {
                _ = try runner.startRecording()
                statusMessage = "Recording..."
                livePartialTranscript = ""
                overlayPhase = .recording
                startLevelMonitoring()
                // Esc cancels only while the mic is hot; the hotkey is released
                // again the moment the session ends so apps get Esc back.
                try? hotkeyController.registerCancelHotkey()
            } catch DictationSessionRunnerError.sessionAlreadyActive {
                // A session is already live; leave its state untouched.
            } catch AudioRecorderError.alreadyRecording {
                // The recorder is already live; leave its state untouched.
            } catch {
                statusMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording() {
        guard isRecording, !isBusy else { return }

        isRecording = false
        isBusy = true
        stopLevelMonitoring()
        statusMessage = "Transcribing..."
        overlayPhase = .transcribing
        hotkeyController.unregisterCancelHotkey()
        let mode = selectedMode

        stopTask = Task {
            do {
                let finalText = try await runner.stopDictation(selectedMode: mode)
                // Show the decoded language when auto-detect chose it: a wrong
                // guess makes Whisper translate, and seeing "en" after
                // speaking French is the fastest way to notice.
                let detected = selectedLanguage == nil
                    ? runner.lastDetectedLanguage.map { ", \($0)" } ?? ""
                    : ""
                let timing = runner.lastTiming.map { " (\($0.summary)\(detected))" } ?? ""
                statusMessage = "Inserted \(finalText.count) characters.\(timing)"
                overlayPhase = .done(finalText)
                canUndoLastInsertion = !finalText.isEmpty
                NotificationCenter.default.post(name: .alowdHistoryChanged, object: nil)
                // Wispr-style auto-learning: re-read the target field shortly
                // after insertion and queue corrected words for review.
                if (try? profileStore.loadSettings().autoLearnFromEdits) ?? true {
                    autoLearn.scheduleLearning(insertedText: finalText)
                }
            } catch is CancellationError {
                statusMessage = "Dictation cancelled."
                overlayPhase = .cancelled
            } catch DictationSessionRunnerError.recordingTooShort {
                statusMessage = hotkeyMode == .pushToTalk
                    ? "Too short — hold \(selectedShortcut.displayName) while you speak."
                    : "Too short — press \(selectedShortcut.displayName) again to stop when you finish speaking."
                overlayPhase = .cancelled
            } catch let error as TextInserterError {
                // Secure input: the transcript was deliberately kept off the
                // shared pasteboard; it is safe in History instead.
                let recovery = error == .secureInputActive
                    ? "The transcript is saved in History."
                    : "The text is on the clipboard for 60 seconds — press Cmd+V to paste it."
                statusMessage = "\(error.localizedDescription) \(recovery)"
                overlayPhase = .error("\(error.localizedDescription) \(recovery)")
                // The transcript was recorded before the insertion attempt.
                NotificationCenter.default.post(name: .alowdHistoryChanged, object: nil)
            } catch {
                if Task.isCancelled {
                    statusMessage = "Recording cancelled."
                    overlayPhase = .cancelled
                } else {
                    statusMessage = "Dictation failed: \(error.localizedDescription)"
                    overlayPhase = .error("Dictation failed: \(error.localizedDescription)")
                }
            }
            stopTask = nil
            syncStateFromRunner()
        }
    }

    func cancelRecording() {
        stopTask?.cancel()
        stopTask = nil
        pushToTalkStopRequested = false
        hotkeyController.unregisterCancelHotkey()
        stopLevelMonitoring()
        runner.cancelRecording()
        syncStateFromRunner()
        statusMessage = "Recording cancelled."
        // Only flash "Cancelled" if the pill was already up for this session.
        if overlayPhase != .hidden {
            overlayPhase = .cancelled
        }
    }

    /// Posts one Cmd+Z into the frontmost app. See UndoKeystrokeSender for why
    /// this beats synthesizing backward deletes.
    func undoLastInsertion() {
        guard canUndoLastInsertion else { return }
        do {
            try UndoKeystrokeSender.postUndo()
            canUndoLastInsertion = false
            statusMessage = "Sent Undo to the frontmost app."
        } catch {
            statusMessage = "Could not undo: \(error.localizedDescription)"
        }
    }

    func refreshModelStatus() {
        let status = WhisperKitModelManager.status(
            in: modelRoot,
            variant: WhisperKitModelVariant.named(modelVariant)
        )
        isModelReady = status.isReady
        modelStatusMessage = status.message
    }

    func installRecommendedModel() {
        guard !isInstallingModel else { return }
        isInstallingModel = true
        modelInstallProgress = nil
        let variant = WhisperKitModelVariant.named(modelVariant)
        modelStatusMessage = "Downloading the \(variant.displayName) WhisperKit model..."

        let root = modelRoot
        Task {
            do {
                _ = try await WhisperKitModelManager.install(variant: variant, in: root) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.modelInstallProgress = progress
                    }
                }
                refreshModelStatus()
            } catch {
                modelStatusMessage = "Model install failed: \(error.localizedDescription)"
            }
            isInstallingModel = false
            modelInstallProgress = nil
        }
    }

    private func loadProfile() {
        do {
            try profileStore.bootstrap()
            let settings = try profileStore.loadSettings()
            applySettings(settings)
            try hotkeyController.register(selectedShortcut)
            statusMessage = hotkeyMode == .pushToTalk
                ? "Ready — hold \(selectedShortcut.displayName) to dictate."
                : "Ready — \(selectedShortcut.displayName) toggles dictation."
            refreshModelStatus()
        } catch {
            statusMessage = "Profile setup failed: \(error.localizedDescription)"
        }
    }

    private func applySettings(_ settings: AppSettings) {
        selectedMode = settings.defaultMode
        selectedShortcut = settings.dictationShortcut
        selectedLanguage = settings.language
        translateToEnglish = settings.translateToEnglish
        hotkeyMode = settings.hotkeyMode
        hotkeyController.pushToTalkEnabled = settings.hotkeyMode == .pushToTalk
        // A Dock tile is what gives the app a running indicator; accessory apps
        // live in the menu bar only and never show one.
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        modelVariant = settings.modelVariant
        showOverlay = settings.showOverlay
    }

    /// Re-reads settings.json after the Settings window saved it, so hotkey
    /// mode, language, and model variant changes take effect immediately.
    private func reloadSettingsFromDisk() {
        guard let settings = try? profileStore.loadSettings() else { return }
        let previousShortcut = selectedShortcut
        applySettings(settings)
        if settings.dictationShortcut != previousShortcut {
            try? hotkeyController.register(settings.dictationShortcut)
        }
        refreshModelStatus()
    }

    /// Retention is enforced at launch: everything older than the configured
    /// window is dropped (best effort; failures never block startup).
    private func pruneHistoryOnLaunch() {
        guard let settings = try? profileStore.loadSettings() else { return }
        _ = try? historyStore.prune(retentionDays: settings.historyRetentionDays)
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestAccessibilityAccessIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    var profileRoot: URL {
        profileStore.root
    }

    /// Menu-bar icon mirrors the dictation state: a hot mic must be visible.
    var menuBarIconName: String {
        if isRecording { return "mic.fill" }
        if isBusy { return "waveform" }
        return "mic"
    }

    private var modelRoot: URL {
        AlowdPaths.whisperKitModelRoot(profileRoot: profileStore.root)
    }

    var modelInstallButtonTitle: String {
        guard let modelInstallProgress else { return "Installing WhisperKit Model..." }
        return "Installing WhisperKit Model (\(Int(modelInstallProgress * 100))%)"
    }

    // MARK: - Live partials support

    /// Streams the recorder's RMS levels into the published inputLevel while
    /// a recording is running; the stream finishes when the capture stops.
    private func startLevelMonitoring() {
        levelTask?.cancel()
        let levels = recorder.inputLevels()
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self, !Task.isCancelled else { return }
                self.inputLevel = level
            }
            self?.inputLevel = 0
        }
    }

    private func stopLevelMonitoring() {
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
    }

    private struct LiveEngineCacheKey: Equatable {
        let profileDirectory: URL
        let language: String?
        let translateToEnglish: Bool
        let modelVariant: String
    }

    /// Prefers the runner's already-loaded WhisperKit engine; otherwise loads
    /// (and caches) a live-only engine from the same model folder.
    private func liveTranscriptionEngine() async throws -> any LiveSampleTranscribing {
        if let shared = runner.cachedLiveSampleTranscriber {
            return shared
        }
        let settings = try profileStore.loadSettings()
        let key = LiveEngineCacheKey(
            profileDirectory: settings.profileDirectory,
            language: settings.language,
            translateToEnglish: settings.translateToEnglish,
            modelVariant: settings.modelVariant
        )
        if let cachedLiveEngine, cachedLiveEngine.key == key {
            return cachedLiveEngine.engine
        }

        let modelRoot = AlowdPaths.whisperKitModelRoot(profileRoot: settings.profileDirectory)
        let variant = WhisperKitModelVariant.named(settings.modelVariant)
        let modelStatus = WhisperKitModelManager.status(in: modelRoot, variant: variant)
        guard let modelDirectory = modelStatus.modelFolder else {
            throw AlowdAppError(modelStatus.message)
        }
        let engine = try await WhisperKitTranscriptionEngine(
            modelPath: modelDirectory,
            modelRoot: modelRoot,
            language: settings.language,
            translateToEnglish: settings.translateToEnglish
        )
        cachedLiveEngine = (key, engine)
        return engine
    }

    private static func makePipeline(settings: AppSettings) async throws -> DictationPipeline {
        let modelRoot = AlowdPaths.whisperKitModelRoot(profileRoot: settings.profileDirectory)
        let variant = WhisperKitModelVariant.named(settings.modelVariant)
        let modelStatus = WhisperKitModelManager.status(in: modelRoot, variant: variant)
        guard let modelDirectory = modelStatus.modelFolder else {
            throw AlowdAppError(
                "\(modelStatus.message) Install it from Alowd's Settings window, then retry."
            )
        }

        let engine = try await WhisperKitTranscriptionEngine(
            modelPath: modelDirectory,
            modelRoot: modelRoot,
            language: settings.language,
            translateToEnglish: settings.translateToEnglish
        )
        let fallback = RuleBasedPostProcessor()
        let processor: PostProcessor = settings.enableOllamaRewrite
            ? OllamaPostProcessor(
                config: OllamaConfig(baseURL: settings.ollamaBaseURL, model: settings.ollamaModel),
                client: URLSessionOllamaHTTPClient(),
                fallback: fallback
            )
            : fallback

        return DictationPipeline(
            engine: engine,
            processor: processor,
            inserter: ClipboardTextInserter()
        )
    }
}

private struct AlowdAppError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        self.errorDescription = message
    }
}

private extension WritingMode {
    var displayName: String {
        switch self {
        case .raw:
            "Raw"
        case .myVoiceCasual:
            "My voice casual"
        case .myVoicePro:
            "My voice pro"
        case .prompt:
            "Prompt"
        }
    }
}
