import Foundation
import Testing
@testable import AlowdCore

struct PermissionStatusTests {
    @Test func missingPermissionsProducePlainLanguageMessage() {
        let status = PermissionStatus(microphone: false, accessibility: false, inputMonitoring: true)
        #expect(
            status.blockingMessage == "Alowd needs microphone and accessibility permission before dictation can work.",
            "Missing permissions must produce plain language message"
        )
    }
}
