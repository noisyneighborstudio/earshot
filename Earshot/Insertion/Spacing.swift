import Foundation

enum Spacing {
    private static let noSpaceBefore = CharacterSet(charactersIn: ".,;:!?)]}…")
    private static let openers = CharacterSet(charactersIn: "([{\"'“‘/-")

    /// Adds a separating space when inserting after a word.
    static func join(before: String, insert: String) -> String {
        guard let last = before.unicodeScalars.last, let first = insert.unicodeScalars.first else { return insert }
        if CharacterSet.whitespacesAndNewlines.contains(last) || openers.contains(last) { return insert }
        if CharacterSet.whitespacesAndNewlines.contains(first) || noSpaceBefore.contains(first) { return insert }
        return " " + insert
    }
}
