import Foundation

public enum WritingMode: String, Codable, CaseIterable, Sendable {
    case raw
    case myVoiceCasual = "my_voice_casual"
    case myVoicePro = "my_voice_pro"
    case prompt
}

public enum DictationShortcut: String, Codable, CaseIterable, Sendable {
    case controlOptionSpace
    case controlOptionD

    public var displayName: String {
        switch self {
        case .controlOptionSpace:
            "⌃⌥Space"
        case .controlOptionD:
            "⌃⌥D"
        }
    }
}

public enum HotkeyMode: String, Codable, CaseIterable, Sendable {
    /// One press starts dictation, the next press stops it (default).
    case toggle
    /// Recording runs only while the hotkey is held down.
    case pushToTalk = "push_to_talk"

    public var displayName: String {
        switch self {
        case .toggle:
            "Toggle"
        case .pushToTalk:
            "Push to talk"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var defaultMode: WritingMode
    public var dictationShortcut: DictationShortcut
    public var retainRawAudio: Bool
    public var enableCloudProcessing: Bool
    public var enableOllamaRewrite: Bool
    public var ollamaBaseURL: URL
    public var ollamaModel: String
    public var profileDirectory: URL
    /// Whisper language code (for example "fr" or "en"); nil means auto-detect.
    public var language: String?
    /// Defaults to true to preserve the app's established behavior of
    /// translating dictation into English.
    public var translateToEnglish: Bool
    /// WhisperKit model variant to transcribe with (for example "base",
    /// "small", or "large-v3-turbo").
    public var modelVariant: String
    /// How the dictation hotkey behaves: toggle or hold-to-dictate.
    public var hotkeyMode: HotkeyMode
    /// Keep history records for this many days; nil keeps them forever.
    public var historyRetentionDays: Int?
    /// Show the floating dictation overlay pill while recording/transcribing.
    public var showOverlay: Bool
    /// Show a Dock icon (and therefore a running indicator). When false the
    /// app lives only in the menu bar.
    public var showInDock: Bool
    /// After an insertion, re-read the target field via Accessibility and turn
    /// the user's manual corrections into dictionary suggestions.
    public var autoLearnFromEdits: Bool

    public static let `default` = AppSettings(
        defaultMode: .myVoiceCasual,
        dictationShortcut: .controlOptionSpace,
        retainRawAudio: false,
        enableCloudProcessing: false,
        enableOllamaRewrite: false,
        ollamaBaseURL: URL(string: "http://127.0.0.1:11434")!,
        ollamaModel: "llama3.2:3b",
        profileDirectory: URL(fileURLWithPath: NSString(string: "~/Alowd").expandingTildeInPath),
        language: nil,
        translateToEnglish: true,
        modelVariant: "base",
        hotkeyMode: .toggle,
        historyRetentionDays: nil,
        showOverlay: true,
        showInDock: true,
        autoLearnFromEdits: true
    )

    public init(
        defaultMode: WritingMode,
        dictationShortcut: DictationShortcut = .controlOptionSpace,
        retainRawAudio: Bool,
        enableCloudProcessing: Bool,
        enableOllamaRewrite: Bool,
        ollamaBaseURL: URL,
        ollamaModel: String,
        profileDirectory: URL,
        language: String? = nil,
        translateToEnglish: Bool = true,
        modelVariant: String = "base",
        hotkeyMode: HotkeyMode = .toggle,
        historyRetentionDays: Int? = nil,
        showOverlay: Bool = true,
        showInDock: Bool = true,
        autoLearnFromEdits: Bool = true
    ) {
        self.defaultMode = defaultMode
        self.dictationShortcut = dictationShortcut
        self.retainRawAudio = retainRawAudio
        self.enableCloudProcessing = enableCloudProcessing
        self.enableOllamaRewrite = enableOllamaRewrite
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaModel = ollamaModel
        self.profileDirectory = profileDirectory
        self.language = language
        self.translateToEnglish = translateToEnglish
        self.modelVariant = modelVariant
        self.hotkeyMode = hotkeyMode
        self.historyRetentionDays = historyRetentionDays
        self.showOverlay = showOverlay
        self.showInDock = showInDock
        self.autoLearnFromEdits = autoLearnFromEdits
    }

    private enum CodingKeys: String, CodingKey {
        case defaultMode
        case dictationShortcut
        case retainRawAudio
        case enableCloudProcessing
        case enableOllamaRewrite
        case ollamaBaseURL
        case ollamaModel
        case profileDirectory
        case language
        case translateToEnglish
        case modelVariant
        case hotkeyMode
        case historyRetentionDays
        case showOverlay
        case showInDock
        case autoLearnFromEdits
    }

    public init(from decoder: Decoder) throws {
        // Tolerant decoding: settings.json files written by older builds keep
        // loading, with missing keys falling back to the defaults.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default
        defaultMode = try container.decodeIfPresent(WritingMode.self, forKey: .defaultMode)
            ?? defaults.defaultMode
        dictationShortcut = try container.decodeIfPresent(DictationShortcut.self, forKey: .dictationShortcut)
            ?? defaults.dictationShortcut
        retainRawAudio = try container.decodeIfPresent(Bool.self, forKey: .retainRawAudio)
            ?? defaults.retainRawAudio
        enableCloudProcessing = try container.decodeIfPresent(Bool.self, forKey: .enableCloudProcessing)
            ?? defaults.enableCloudProcessing
        enableOllamaRewrite = try container.decodeIfPresent(Bool.self, forKey: .enableOllamaRewrite)
            ?? defaults.enableOllamaRewrite
        ollamaBaseURL = try container.decodeIfPresent(URL.self, forKey: .ollamaBaseURL)
            ?? defaults.ollamaBaseURL
        ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel)
            ?? defaults.ollamaModel
        profileDirectory = try container.decodeIfPresent(URL.self, forKey: .profileDirectory)
            ?? defaults.profileDirectory
        language = try container.decodeIfPresent(String.self, forKey: .language)
            ?? defaults.language
        translateToEnglish = try container.decodeIfPresent(Bool.self, forKey: .translateToEnglish)
            ?? defaults.translateToEnglish
        modelVariant = try container.decodeIfPresent(String.self, forKey: .modelVariant)
            ?? defaults.modelVariant
        hotkeyMode = try container.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode)
            ?? defaults.hotkeyMode
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays)
            ?? defaults.historyRetentionDays
        showOverlay = try container.decodeIfPresent(Bool.self, forKey: .showOverlay)
            ?? defaults.showOverlay
        showInDock = try container.decodeIfPresent(Bool.self, forKey: .showInDock)
            ?? defaults.showInDock
        autoLearnFromEdits = try container.decodeIfPresent(Bool.self, forKey: .autoLearnFromEdits)
            ?? defaults.autoLearnFromEdits
    }
}

public struct DictionaryTerm: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var phrase: String
    public var replacement: String
    public var source: String
    public var createdAt: Date

    public init(id: UUID = UUID(), phrase: String, replacement: String, source: String, createdAt: Date = Date()) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.source = source
        self.createdAt = createdAt
    }
}

public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

public struct TranscriptRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var mode: WritingMode
    public var rawText: String
    public var finalText: String
    public var appBundleIdentifier: String?
    public var createdAt: Date
    public var retainedAudioPath: String?
    /// Recorded audio length in seconds, when known. Optional so records
    /// written before this field existed keep decoding.
    public var audioDurationSeconds: TimeInterval?

    public init(
        id: UUID = UUID(),
        mode: WritingMode,
        rawText: String,
        finalText: String,
        appBundleIdentifier: String? = nil,
        createdAt: Date = Date(),
        retainedAudioPath: String? = nil,
        audioDurationSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.mode = mode
        self.rawText = rawText
        self.finalText = finalText
        self.appBundleIdentifier = appBundleIdentifier
        self.createdAt = createdAt
        self.retainedAudioPath = retainedAudioPath
        self.audioDurationSeconds = audioDurationSeconds
    }
}
