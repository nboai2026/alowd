import Foundation
import Testing
@testable import AlowdCore

struct LearningAnchorTests {
    @Test func fieldStillShowingTheInsertionIsLearnable() {
        #expect(LearningAnchor.fieldPlausiblyContainsInsertion(
            insertedText: "Deploy the WhisperKit pipeline tomorrow morning",
            fieldText: "Deploy the WisperKit pipeline tomorrow morning"
        ), "A field holding our text with one misspelling is exactly what we learn from")
    }

    @Test func unrelatedFieldContentIsRejected() {
        // The user switched to another app during the delay; whatever is
        // focused now must never be diffed or persisted.
        #expect(!LearningAnchor.fieldPlausiblyContainsInsertion(
            insertedText: "Deploy the WhisperKit pipeline tomorrow morning",
            fieldText: "correct horse battery staple bank account"
        ), "Text from an unrelated field must not be learned from")
    }

    @Test func emptyOrTrivialInsertionIsRejected() {
        #expect(!LearningAnchor.fieldPlausiblyContainsInsertion(insertedText: "", fieldText: "anything"))
        #expect(!LearningAnchor.fieldPlausiblyContainsInsertion(insertedText: "ok go", fieldText: "ok go"),
                "Too few distinctive words to anchor on")
    }

    @Test func partiallyEditedInsertionStillAnchors() {
        #expect(LearningAnchor.fieldPlausiblyContainsInsertion(
            insertedText: "send the quarterly revenue summary to marketing",
            fieldText: "Send the quarterly revenue summary to the marketing team today"
        ), "Light editing around our text must not break learning")
    }
}
