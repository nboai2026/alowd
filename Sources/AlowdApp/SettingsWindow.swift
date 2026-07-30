import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement
import AlowdCore

extension Notification.Name {
    /// Posted after the Settings window saves settings.json, so the menu-bar
    /// model can re-read hotkey mode, language, variant, and the rest.
    static let alowdSettingsChanged = Notification.Name("AlowdSettingsChanged")
}

struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings...") {
            openWindow(id: SettingsWindowID.value)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

enum SettingsWindowID {
    static let value = "settings"
}

@MainActor
final class SettingsWindowModel: ObservableObject {
    @Published var settings: AppSettings = .default
    @Published var errorMessage: String?

    // Model section
    @Published var variantStates: [String: WhisperKitModelStatus] = [:]
    @Published var installingVariantID: String?
    @Published var installProgress: Double?

    // Ollama section
    @Published var ollamaBaseURLText: String = AppSettings.default.ollamaBaseURL.absoluteString
    @Published var ollamaTestResult: String?
    @Published var isTestingOllama = false

    // General section
    @Published var launchAtLogin = false
    @Published var launchAtLoginMessage: String?

    // Permissions section
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false

    private let profileStore: ProfileStore

    init(profileStore: ProfileStore = ProfileStore()) {
        self.profileStore = profileStore
    }

    func reload() {
        do {
            try profileStore.bootstrap()
            settings = try profileStore.loadSettings()
            ollamaBaseURLText = settings.ollamaBaseURL.absoluteString
            errorMessage = nil
        } catch {
            errorMessage = "Could not load settings: \(error.localizedDescription)"
        }
        refreshVariantStates()
        refreshPermissions()
        refreshLaunchAtLogin()
    }

    /// Persists the current settings and tells the menu-bar model to re-read them.
    func save(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        do {
            try profileStore.bootstrap()
            try profileStore.saveSettings(settings)
            errorMessage = nil
            NotificationCenter.default.post(name: .alowdSettingsChanged, object: nil)
        } catch {
            errorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Model variants

    var modelRoot: URL {
        AlowdPaths.whisperKitModelRoot(profileRoot: profileStore.root)
    }

    func refreshVariantStates() {
        var states: [String: WhisperKitModelStatus] = [:]
        for variant in WhisperKitModelVariant.supported {
            states[variant.id] = WhisperKitModelManager.status(in: modelRoot, variant: variant)
        }
        variantStates = states
    }

    func install(_ variant: WhisperKitModelVariant) {
        guard installingVariantID == nil else { return }
        installingVariantID = variant.id
        installProgress = nil

        let root = modelRoot
        Task {
            do {
                _ = try await WhisperKitModelManager.install(variant: variant, in: root) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.installProgress = progress
                    }
                }
                errorMessage = nil
            } catch {
                errorMessage = "Install of \(variant.displayName) failed: \(error.localizedDescription)"
            }
            installingVariantID = nil
            installProgress = nil
            refreshVariantStates()
        }
    }

    // MARK: - Ollama

    func saveOllamaBaseURL() {
        guard
            let url = URL(string: ollamaBaseURLText.trimmingCharacters(in: .whitespaces)),
            url.host == "127.0.0.1" || url.host == "localhost"
        else {
            errorMessage = "The Ollama URL must point at localhost (for example http://127.0.0.1:11434)."
            return
        }
        save { $0.ollamaBaseURL = url }
    }

    func testOllamaConnection() {
        guard !isTestingOllama else { return }
        isTestingOllama = true
        ollamaTestResult = nil
        let baseURL = settings.ollamaBaseURL
        let expectedModel = settings.ollamaModel

        Task {
            do {
                let models = try await OllamaConnectionTester.listModels(baseURL: baseURL)
                if models.contains(expectedModel) {
                    ollamaTestResult = "Connected — \(expectedModel) is available."
                } else if models.isEmpty {
                    ollamaTestResult = "Connected, but Ollama has no models. Run `ollama pull \(expectedModel)`."
                } else {
                    ollamaTestResult = "Connected, but \(expectedModel) is not installed (found: \(models.joined(separator: ", ")))."
                }
            } catch {
                ollamaTestResult = "Connection failed: \(error.localizedDescription)"
            }
            isTestingOllama = false
        }
    }

    // MARK: - Launch at login

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginMessage = nil
        } catch {
            // A bare SPM executable (no .app bundle) cannot register; surface why.
            launchAtLoginMessage = "Launch at login is unavailable: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    // MARK: - Permissions

    func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
    }

    func openSystemSettings(pane: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsWindowModel

    var body: some View {
        Form {
            modelSection
            languageSection
            ollamaSection
            privacySection
            generalSection
            permissionsSection

            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { model.reload() }
    }

    private var modelSection: some View {
        Section("Model") {
            Picker("Transcription model", selection: Binding(
                get: { model.settings.modelVariant },
                set: { newValue in model.save { $0.modelVariant = newValue } }
            )) {
                ForEach(WhisperKitModelVariant.supported) { variant in
                    Text(variant.displayName).tag(variant.id)
                }
            }

            ForEach(WhisperKitModelVariant.supported) { variant in
                variantRow(variant)
            }
        }
    }

    @ViewBuilder
    private func variantRow(_ variant: WhisperKitModelVariant) -> some View {
        let status = model.variantStates[variant.id]
        let isInstalling = model.installingVariantID == variant.id
        HStack {
            Image(systemName: status?.isReady == true ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(status?.isReady == true ? Color.green : Color.secondary)
            VStack(alignment: .leading) {
                Text(variant.displayName)
                Text(status?.isReady == true ? "Installed" : (status?.message ?? "Not installed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isInstalling {
                if let progress = model.installProgress {
                    ProgressView(value: progress).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if status?.isReady != true {
                Button("Install") { model.install(variant) }
                    .disabled(model.installingVariantID != nil)
            }
        }
    }

    private var languageSection: some View {
        Section("Language") {
            Picker("Spoken language", selection: Binding(
                get: { model.settings.language },
                set: { newValue in model.save { $0.language = newValue } }
            )) {
                Text("Auto").tag(nil as String?)
                Text("Français").tag("fr" as String?)
                Text("English").tag("en" as String?)
            }
            Toggle("Translate to English", isOn: Binding(
                get: { model.settings.translateToEnglish },
                set: { newValue in model.save { $0.translateToEnglish = newValue } }
            ))
        }
    }

    private var ollamaSection: some View {
        Section("Ollama rewrite") {
            Toggle("Rewrite with local Ollama", isOn: Binding(
                get: { model.settings.enableOllamaRewrite },
                set: { newValue in model.save { $0.enableOllamaRewrite = newValue } }
            ))
            TextField("Model", text: Binding(
                get: { model.settings.ollamaModel },
                set: { newValue in model.save { $0.ollamaModel = newValue } }
            ))
            TextField("Base URL (localhost only)", text: $model.ollamaBaseURLText)
                .onSubmit { model.saveOllamaBaseURL() }
            HStack {
                Button("Test connection") {
                    model.saveOllamaBaseURL()
                    model.testOllamaConnection()
                }
                .disabled(model.isTestingOllama)
                if model.isTestingOllama {
                    ProgressView().controlSize(.small)
                }
            }
            if let result = model.ollamaTestResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Toggle("Learn vocabulary from your edits", isOn: Binding(
                get: { model.settings.autoLearnFromEdits },
                set: { newValue in model.save { $0.autoLearnFromEdits = newValue } }
            ))
            Text("Shortly after inserting a dictation, Alowd re-reads that field through Accessibility and suggests your corrections as dictionary entries. Turn off to never read other apps after inserting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Keep raw audio recordings", isOn: Binding(
                get: { model.settings.retainRawAudio },
                set: { newValue in model.save { $0.retainRawAudio = newValue } }
            ))
            Picker("Keep history", selection: Binding(
                get: { model.settings.historyRetentionDays },
                set: { newValue in model.save { $0.historyRetentionDays = newValue } }
            )) {
                Text("Forever").tag(nil as Int?)
                Text("90 days").tag(90 as Int?)
                Text("30 days").tag(30 as Int?)
                Text("7 days").tag(7 as Int?)
            }
            Text("Old dictations are pruned when Alowd starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if let message = model.launchAtLoginMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Hotkey behavior", selection: Binding(
                get: { model.settings.hotkeyMode },
                set: { newValue in model.save { $0.hotkeyMode = newValue } }
            )) {
                ForEach(HotkeyMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Text("Push to talk records only while the shortcut is held down. Esc cancels a recording in either mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show dictation overlay", isOn: Binding(
                get: { model.settings.showOverlay },
                set: { newValue in model.save { $0.showOverlay = newValue } }
            ))
            Text("A small floating pill near the bottom of the screen with live levels and the partial transcript while you dictate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show in Dock", isOn: Binding(
                get: { model.settings.showInDock },
                set: { newValue in model.save { $0.showInDock = newValue } }
            ))
            Text("Keeps a Dock icon with a running indicator. Turn off to live in the menu bar only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(
                title: "Microphone",
                granted: model.microphoneGranted,
                pane: "Privacy_Microphone"
            )
            permissionRow(
                title: "Accessibility",
                granted: model.accessibilityGranted,
                pane: "Privacy_Accessibility"
            )
            Button("Refresh status") { model.refreshPermissions() }
        }
    }

    private func permissionRow(title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            if !granted {
                Button("Open System Settings") { model.openSystemSettings(pane: pane) }
            }
        }
    }
}
