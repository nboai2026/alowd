import Foundation
import Testing
@testable import AlowdCore

struct AlowdModelsTests {
    @Test func writingModesAreExactlyV1Modes() {
        #expect(WritingMode.allCases.map(\.rawValue) == [
            "raw",
            "my_voice_casual",
            "my_voice_pro",
            "prompt"
        ], "Writing modes must match V1 mode set")
    }

    @Test func defaultSettingsAreLocalFirst() {
        let settings = AppSettings.default
        #expect(settings.defaultMode == .myVoiceCasual, "Default mode must be My voice casual")
        #expect(settings.dictationShortcut == .controlOptionSpace, "Default shortcut must be Control-Option-Space")
        #expect(!settings.retainRawAudio, "Raw audio retention must default off")
        #expect(!settings.enableCloudProcessing, "Cloud processing must default off")
        #expect(!settings.enableOllamaRewrite, "Ollama rewrite must default off")
        #expect(
            settings.profileDirectory.path == NSString(string: "~/Alowd").expandingTildeInPath,
            "Default profile directory must be ~/Alowd"
        )
    }

    @Test func legacySettingsDefaultToControlOptionSpace() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("""
        {
          "defaultMode": "my_voice_casual",
          "retainRawAudio": false,
          "enableCloudProcessing": false,
          "enableOllamaRewrite": false,
          "ollamaBaseURL": "http://127.0.0.1:11434",
          "ollamaModel": "llama3.2:3b",
          "profileDirectory": "file:///tmp/Alowd"
        }
        """.utf8))
        #expect(
            settings.dictationShortcut == .controlOptionSpace,
            "Existing profiles must gain the default shortcut"
        )
    }

    @Test func legacySettingsWithoutLanguageFieldsStillLoad() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("""
        {
          "defaultMode": "my_voice_casual",
          "dictationShortcut": "controlOptionSpace",
          "retainRawAudio": false,
          "enableCloudProcessing": false,
          "enableOllamaRewrite": false,
          "ollamaBaseURL": "http://127.0.0.1:11434",
          "ollamaModel": "llama3.2:3b",
          "profileDirectory": "file:///tmp/Alowd"
        }
        """.utf8))
        #expect(settings.language == nil, "Old settings must default to auto language detection")
        #expect(settings.translateToEnglish, "Old settings must keep the established translate-to-English behavior")
    }

    @Test func emptySettingsObjectDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings == AppSettings.default, "A settings file with no keys must decode to the defaults")
    }

    @Test func legacySettingsWithoutV2FieldsStillLoad() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("""
        {
          "defaultMode": "my_voice_casual",
          "dictationShortcut": "controlOptionSpace",
          "retainRawAudio": false,
          "enableCloudProcessing": false,
          "enableOllamaRewrite": false,
          "ollamaBaseURL": "http://127.0.0.1:11434",
          "ollamaModel": "llama3.2:3b",
          "profileDirectory": "file:///tmp/Alowd",
          "language": "fr",
          "translateToEnglish": false
        }
        """.utf8))
        #expect(settings.modelVariant == "base", "Old settings must default to the base variant")
        #expect(settings.hotkeyMode == .toggle, "Old settings must keep the toggle hotkey behavior")
        #expect(settings.historyRetentionDays == nil, "Old settings must keep history forever")
    }

    @Test func v2SettingsFieldsRoundTrip() throws {
        var settings = AppSettings.default
        settings.modelVariant = "large-v3-turbo"
        settings.hotkeyMode = .pushToTalk
        settings.historyRetentionDays = 30

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.modelVariant == "large-v3-turbo", "Model variant must round trip")
        #expect(decoded.hotkeyMode == .pushToTalk, "Hotkey mode must round trip")
        #expect(decoded.historyRetentionDays == 30, "History retention must round trip")
    }

    @Test func legacySettingsWithoutShowOverlayDefaultToOn() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("""
        {
          "defaultMode": "my_voice_casual",
          "dictationShortcut": "controlOptionSpace",
          "hotkeyMode": "toggle"
        }
        """.utf8))
        #expect(settings.showOverlay, "Old settings files must default to showing the dictation overlay")
    }

    @Test func showOverlayRoundTrips() throws {
        var settings = AppSettings.default
        settings.showOverlay = false

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(!decoded.showOverlay, "A disabled overlay must round trip")
    }

    @Test func unknownHotkeyModeFailsWithoutBreakingKnownValues() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("""
        {"hotkeyMode": "push_to_talk"}
        """.utf8))
        #expect(decoded.hotkeyMode == .pushToTalk, "The stable raw value must decode to push-to-talk")
    }
}

extension AlowdModelsTests {
    @Test func legacySettingsWithoutDockFieldDefaultToShowingInDock() throws {
        let json = Data("""
        {"defaultMode":"my_voice_casual","showOverlay":true}
        """.utf8)
        let settings = try AlowdJSONCoding.makeDecoder().decode(AppSettings.self, from: json)
        #expect(settings.showInDock, "Profiles written before the Dock setting must still show a Dock icon")
    }
}

struct SpokenLanguageTests {
    @Test func autoIsFirstAndCarriesNoCode() {
        #expect(SpokenLanguage.supported.first?.code == nil, "Auto-detect must be the first option")
    }

    @Test func codesAreUniqueAndWhisperShaped() {
        let codes = SpokenLanguage.supported.compactMap(\.code)
        #expect(Set(codes).count == codes.count, "Language codes must be unique")
        #expect(codes.allSatisfy { $0.count == 2 }, "Whisper expects two-letter language codes")
    }

    @Test func coversTheAdvertisedLanguages() {
        let codes = Set(SpokenLanguage.supported.compactMap(\.code))
        #expect(codes.isSuperset(of: ["en", "fr", "es", "de"]), "English, French, Spanish and German must be selectable")
    }
}
