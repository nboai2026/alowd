#if os(macOS)
import Carbon.HIToolbox
#endif
import Testing
@testable import AlowdCore

struct HotkeyControllerTests {
    @Test func eachPressInvokesExactlyOneToggle() {
        var toggleCount = 0
        let controller = HotkeyController(handlers: .init {
            toggleCount += 1
        })

        controller.triggerForTesting()
        controller.triggerForTesting()

        #expect(toggleCount == 2, "Each hotkey press must invoke exactly one toggle")
    }

    #if os(macOS)
    @MainActor @Test func toggleModeFiresOnToggleOncePerPressDespiteAutoRepeat() {
        var toggles = 0
        var presses = 0
        let controller = HotkeyController(handlers: .init(
            onToggle: { toggles += 1 },
            onPress: { presses += 1 }
        ))

        controller.simulateHotkeyPressForTesting()
        controller.simulateHotkeyPressForTesting() // auto-repeat while held
        controller.simulateHotkeyReleaseForTesting()

        #expect(toggles == 1, "Toggle mode must fire exactly once per physical press")
        #expect(presses == 0, "Toggle mode must never fire the push-to-talk press handler")
    }

    @MainActor @Test func pushToTalkFiresPressOnDownAndReleaseOnUp() {
        var toggles = 0
        var presses = 0
        var releases = 0
        let controller = HotkeyController(handlers: .init(
            onToggle: { toggles += 1 },
            onPress: { presses += 1 },
            onRelease: { releases += 1 }
        ))
        controller.pushToTalkEnabled = true

        controller.simulateHotkeyPressForTesting()
        controller.simulateHotkeyPressForTesting() // auto-repeat while held
        controller.simulateHotkeyReleaseForTesting()
        controller.simulateHotkeyPressForTesting()
        controller.simulateHotkeyReleaseForTesting()

        #expect(presses == 2, "Push-to-talk must fire one press per physical key-down")
        #expect(releases == 2, "Push-to-talk must fire one release per key-up")
        #expect(toggles == 0, "Push-to-talk must never fire the toggle handler")
    }

    @MainActor @Test func pushToTalkIgnoresReleaseWithoutAPrecedingPress() {
        var releases = 0
        let controller = HotkeyController(handlers: .init(
            onToggle: {},
            onRelease: { releases += 1 }
        ))
        controller.pushToTalkEnabled = true

        controller.simulateHotkeyReleaseForTesting()

        #expect(releases == 0, "A stray release without a press must not fire onRelease")
    }

    @Test func shortcutsMapToExpectedCarbonKeyCodes() {
        #expect(DictationShortcut.controlOptionSpace.keyCode == UInt32(kVK_Space), "Control-Option-Space must map to the Space key code")
        #expect(DictationShortcut.controlOptionD.keyCode == UInt32(kVK_ANSI_D), "Control-Option-D must map to the D key code")
    }

    @Test func shortcutsUseControlOptionModifiers() {
        for shortcut in DictationShortcut.allCases {
            #expect(
                shortcut.carbonModifiers == UInt32(controlKey | optionKey),
                "Every dictation shortcut must use the Control-Option modifiers"
            )
        }
    }
    #endif
}
