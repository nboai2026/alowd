import Foundation

/// Guards the auto-learning re-read: we may only learn from a field that still
/// plausibly contains the text we inserted. Without this anchor, a delayed read
/// can capture content the user typed somewhere else entirely — a password, a
/// message, a bank page — and persist fragments of it as "suggestions".
public enum LearningAnchor {
    /// Fraction of distinctive inserted words that must still be present.
    static let requiredOverlap = 0.5

    public static func fieldPlausiblyContainsInsertion(
        insertedText: String,
        fieldText: String
    ) -> Bool {
        let inserted = distinctiveWords(insertedText)
        guard !inserted.isEmpty else { return false }
        let field = Set(distinctiveWords(fieldText))
        let matched = inserted.filter { field.contains($0) }.count
        return Double(matched) / Double(inserted.count) >= requiredOverlap
    }

    private static func distinctiveWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
    }
}
