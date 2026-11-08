import AppKit
import os

/// Notices when the user edits text Earshot just pasted, and records corrected words as
/// dictionary suggestions ("You've corrected 'Lyft' 3 times. Add it?").
///
/// After a paste it checks back once — ~25 s later, or when the next paste happens — reading the
/// focused field (only if the same app is still frontmost), finds the pasted region by its
/// before-text anchor, and word-aligns what was pasted against what's there now.
@MainActor
final class CorrectionTracker {
    private struct Pending {
        let text: String
        let context: FocusContext
    }

    private let suggestions: DictionarySuggestions
    private let settings: AppSettings
    private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "corrections")
    private var pending: Pending?
    private var check: Task<Void, Never>?

    static let delay: Duration = .seconds(25)

    init(suggestions: DictionarySuggestions, settings: AppSettings) {
        self.suggestions = suggestions
        self.settings = settings
    }

    /// Called right after a successful paste of `text` into the field described by `context`.
    func didInsert(_ text: String, context: FocusContext) {
        // The previous insert's edits (if any) are as final as they'll get: evaluate it now.
        if let previous = pending { evaluate(previous) }
        check?.cancel()
        guard !context.bundleID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pending = nil
            return
        }
        pending = Pending(text: text, context: context)
        check = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self, let due = self.pending else { return }
            self.pending = nil
            self.evaluate(due)
        }
    }

    private func evaluate(_ insert: Pending) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == insert.context.bundleID else {
            log.debug("skipped: app no longer frontmost")
            return
        }
        guard let now = FocusReader.focusedText(), now.bundleID == insert.context.bundleID else { return }
        let field = now.text
        let anchor = Self.anchor(insert.context.before)
        guard let region = Self.region(in: field, after: anchor, pastedWordCount: Self.tokens(insert.text).count) else {
            log.debug("skipped: pasted text not found in field")
            return
        }
        let words = Self.corrections(pasted: insert.text, current: region, startsSentence: Self.endsSentence(anchor))
        guard !words.isEmpty else { return }
        log.info("recorded \(words.count, privacy: .public) corrected word(s)")
        suggestions.record(words, dictionary: settings.dictionary)
    }

    // MARK: - Pure logic

    struct Token: Equatable {
        /// The word without surrounding punctuation, as typed.
        let word: String
        /// Lowercased, for matching.
        let key: String
        /// The raw token ended a sentence (".", "!", "?").
        let endsSentence: Bool
    }

    nonisolated static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !word.isEmpty else { return nil }
            let last = raw.last.map { ".!?".contains($0) } ?? false
            return Token(word: word, key: word.lowercased(), endsSentence: last)
        }
    }

    /// The last ~60 characters before the cursor at dictation time, used to find the insert later.
    nonisolated static func anchor(_ before: String) -> String {
        String(before.suffix(60))
    }

    nonisolated static func endsSentence(_ anchor: String) -> Bool {
        let trimmed = anchor.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return true }
        return ".!?\n".contains(last)
    }

    /// The part of `field` where the paste should be: just after the anchor (trying shorter
    /// suffixes when text near it was edited), or the whole field when there was no anchor.
    /// nil when the anchor can't be found at all.
    nonisolated static func region(in field: String, after anchor: String, pastedWordCount: Int) -> String? {
        let limit = pastedWordCount * 2 + 5
        let trimmedAnchor = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnchor.isEmpty else {
            return field.split(whereSeparator: \.isWhitespace).prefix(max(limit, 400)).joined(separator: " ")
        }
        // Longest suffix first; shorter ones survive edits made just before the insert.
        var lengths: [Int] = []
        for length in [60, 30, 15].map({ min($0, trimmedAnchor.count) }) where !lengths.contains(length) {
            lengths.append(length)
        }
        for length in lengths {
            let suffix = String(trimmedAnchor.suffix(length))
            guard let range = field.range(of: suffix, options: .backwards) else { continue }
            return field[range.upperBound...].split(whereSeparator: \.isWhitespace).prefix(limit).joined(separator: " ")
        }
        return nil
    }

    /// Words the user typed over dictated ones that look worth learning. Empty for a wholesale rewrite.
    nonisolated static func corrections(pasted: String, current: String, startsSentence: Bool) -> [String] {
        let old = tokens(pasted)
        let new = tokens(current)
        guard !old.isEmpty, !new.isEmpty else { return [] }

        let pairs = lcs(old.map(\.key), new.map(\.key))
        // A heavy rewrite isn't a spelling fix.
        if old.count > 3, Double(pairs.count) / Double(old.count) < 0.5 { return [] }

        var found: [(index: Int, word: String)] = []
        // Walk the gaps between matched words; each gap is a block of removed and typed words.
        var oi = 0, ni = 0
        for (mo, mn) in pairs + [(old.count, new.count)] {
            let removed = Array(old[oi..<mo])
            let typedRange = ni..<mn
            if !removed.isEmpty, !typedRange.isEmpty {
                found += fixes(removed: removed, typed: Array(new[typedRange]), typedStart: ni, in: new, startsSentence: startsSentence)
            }
            // Same word, new casing: only inner capitals or digits ("ios" → "iOS", "s3" → "S3") are
            // unambiguous; a first-letter capital could just be sentence or title case.
            if mo < old.count, mn < new.count, old[mo].word != new[mn].word, isCasingTerm(new[mn].word) {
                found.append((mn, new[mn].word))
            }
            oi = mo + 1
            ni = mn + 1
        }
        var seen = Set<String>()
        return found.sorted { $0.index < $1.index }.map(\.word).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Pairs removed words with similar typed words, in order (a removed pair may merge: "git hub" → "GitHub").
    nonisolated private static func fixes(
        removed: [Token], typed: [Token], typedStart: Int, in new: [Token], startsSentence: Bool
    ) -> [(index: Int, word: String)] {
        var results: [(index: Int, word: String)] = []
        var next = 0
        var r = 0
        while r < removed.count {
            let single = removed[r].key
            let joined = r + 1 < removed.count ? single + removed[r + 1].key : nil
            var matched = false
            for t in next..<typed.count {
                let candidate = typed[t]
                let index = typedStart + t
                let atSentenceStart = index == 0 ? startsSentence : new[index - 1].endsSentence
                if let joined, candidate.key.replacingOccurrences(of: "-", with: "") == joined, isTerm(candidate.word, atSentenceStart: atSentenceStart) {
                    results.append((index, candidate.word))
                    next = t + 1
                    r += 2
                    matched = true
                    break
                }
                if candidate.key != single, similar(single, candidate.key), isTerm(candidate.word, atSentenceStart: atSentenceStart) {
                    results.append((index, candidate.word))
                    next = t + 1
                    r += 1
                    matched = true
                    break
                }
            }
            if !matched { r += 1 }
        }
        return results
    }

    /// Proper nouns and jargon: digits, inner capitals ("iOS", "GitHub"), or a capital not explained by a sentence start.
    nonisolated static func isTerm(_ word: String, atSentenceStart: Bool) -> Bool {
        guard word.contains(where: \.isLetter) else { return false }
        if word.contains(where: \.isNumber) { return true }
        if word.dropFirst().contains(where: \.isUppercase) { return true }
        return !atSentenceStart && (word.first?.isUppercase ?? false)
    }

    nonisolated static func isCasingTerm(_ word: String) -> Bool {
        word.contains(where: \.isLetter) && (word.dropFirst().contains(where: \.isUppercase) || word.contains(where: \.isNumber))
    }

    /// Close enough to be a fix of the same word rather than a different one.
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        let distance = levenshtein(a, b)
        let longest = max(a.count, b.count)
        return longest > 0 && distance <= max(2, longest / 2) && distance < longest
    }

    nonisolated static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }

    /// Index pairs of a longest common subsequence, in order.
    nonisolated static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
