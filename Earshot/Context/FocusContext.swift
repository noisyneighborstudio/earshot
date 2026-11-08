import Foundation

/// Where a dictation is going: the frontmost app and the text before the cursor.
struct FocusContext: Sendable, Equatable {
    var appName = ""
    var bundleID = ""
    var before = ""

    static let maxBefore = 1500

    /// Text before the selection in a field's value (selection is an NSRange in UTF-16 units, as AX reports it).
    static func before(_ value: String, selection: NSRange?) -> String {
        let ns = value as NSString
        guard let selection, selection.location >= 0, NSMaxRange(selection) <= ns.length else {
            // No usable selection: assume the cursor is at the end.
            return ns.substring(from: max(0, ns.length - maxBefore))
        }
        let start = max(0, selection.location - maxBefore)
        return ns.substring(with: NSRange(location: start, length: selection.location - start))
    }
}
