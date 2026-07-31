import Foundation

/// A language Alowd offers in its menus, paired with the Whisper language code
/// sent to the transcription engine.
///
/// Single source of truth for the menu-bar picker and the Settings picker, so
/// adding a language is one line here rather than an edit in each menu.
/// WhisperKit's multilingual models cover far more languages than this list —
/// entries are added as they are actually tried, not speculatively.
public struct SpokenLanguage: Identifiable, Equatable, Sendable {
    /// Whisper language code (for example "es"); nil means auto-detect.
    public let code: String?
    /// Shown in the picker, written in the language itself.
    public let displayName: String

    public var id: String { code ?? "auto" }

    public init(code: String?, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public static let supported: [SpokenLanguage] = [
        SpokenLanguage(code: nil, displayName: "Auto"),
        SpokenLanguage(code: "en", displayName: "English"),
        SpokenLanguage(code: "fr", displayName: "Français"),
        SpokenLanguage(code: "es", displayName: "Español"),
        SpokenLanguage(code: "pt", displayName: "Português"),
        SpokenLanguage(code: "de", displayName: "Deutsch")
    ]
}
