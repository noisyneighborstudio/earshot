import Foundation
import NaturalLanguage

/// Search terms: words split on ICU boundaries (so CJK splits too), case/diacritic/width-folded,
/// with a light plural and possessive trim so "meetings" finds "meeting".
enum Terms {
    static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    static func fold(_ text: String) -> String { text.folding(options: foldOptions, locale: nil) }

    static func of(_ text: String) -> [String] {
        let text = fold(text)
        var terms: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            guard var word, word.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            if word.hasSuffix("'s") || word.hasSuffix("’s") {
                word.removeLast(2)
            } else if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") {
                word.removeLast()
            }
            terms.append(word)
        }
        return terms
    }

    /// Unique terms in query order.
    static func query(_ text: String) -> [String] {
        var seen = Set<String>()
        return of(text).filter { seen.insert($0).inserted }
    }

    /// ~`width` characters of `text` around the first match of any term.
    static func excerpt(_ text: String, around terms: [String], width: Int = 220) -> String {
        guard text.count > width else { return text }
        let hit = terms.compactMap { text.range(of: $0, options: foldOptions)?.lowerBound }.min()
        let lower = hit.flatMap { text.index($0, offsetBy: -width / 3, limitedBy: text.startIndex) } ?? text.startIndex
        let upper = text.index(lower, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
        return (lower > text.startIndex ? "…" : "") + text[lower..<upper] + (upper < text.endIndex ? "…" : "")
    }
}

/// A searchable piece of a meeting.
struct Chunk: Sendable {
    enum Field: String, Sendable, Encodable {
        case title, people, notes, actionItem = "action_item", transcript

        var weight: Double {
            switch self {
            case .title: 3
            case .people: 2
            case .notes, .actionItem: 1.5
            case .transcript: 1
            }
        }
    }

    let field: Field
    let text: String
    /// Transcript lines this chunk covers.
    let lines: Range<Int>
    let terms: [String: Int]
    let length: Int

    init(_ field: Field, _ text: String, lines: Range<Int> = 0..<0) {
        self.field = field
        self.text = text
        self.lines = lines
        let all = Terms.of(text)
        terms = all.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        length = all.count
    }
}

/// A meeting split into chunks for ranking.
struct NotesDocument: Sendable {
    let meeting: Meeting
    let chunks: [Chunk]
    /// Participants plus transcript speaker names.
    let people: [String]
    /// Title and the start of the notes (or transcript): what semantic search embeds.
    let gist: String

    init(_ meeting: Meeting) {
        self.meeting = meeting
        people = Array(Set((meeting.participants ?? []) + meeting.lines.compactMap(\.name))).sorted()
        var chunks = [Chunk(.title, meeting.title)]
        if !people.isEmpty { chunks.append(Chunk(.people, people.joined(separator: ", "))) }
        var prose: [String] = []
        for raw in (meeting.summary ?? "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let task = ["- [ ] ", "- [x] ", "- [X] "].contains { line.hasPrefix($0) }
            chunks.append(Chunk(task ? .actionItem : .notes, line))
            prose.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "-*[]xX ")))
        }
        var start = 0, size = 0
        for (index, line) in meeting.lines.enumerated() {
            size += line.text.count
            guard size >= 400 || index == meeting.lines.count - 1 else { continue }
            chunks.append(Chunk(.transcript, meeting.lines[start...index].map(\.text).joined(separator: " "),
                                lines: start..<index + 1))
            start = index + 1
            size = 0
        }
        self.chunks = chunks
        let body = prose.isEmpty ? meeting.lines.map(\.text) : prose
        gist = String((meeting.title + ". " + body.joined(separator: " ")).prefix(600))
    }

    /// Where `terms` appear in a chunk, as an excerpt; transcript excerpts point at their line.
    func snippet(_ chunk: Chunk, terms: [String]) -> Snippet {
        guard chunk.field == .transcript else {
            return Snippet(field: chunk.field, text: Terms.excerpt(chunk.text, around: terms))
        }
        let index = chunk.lines.first { index in
            terms.contains { meeting.lines[index].text.range(of: $0, options: Terms.foldOptions) != nil }
        } ?? chunk.lines.lowerBound
        let line = meeting.lines[index]
        return Snippet(field: .transcript, text: line.label + ": " + Terms.excerpt(line.text, around: terms),
                       line: index, at: Meeting.timestamp(line.start))
    }
}

struct Snippet: Encodable, Sendable {
    let field: Chunk.Field
    let text: String
    /// Transcript line index, for `get_meeting`'s `transcript_offset`.
    var line: Int?
    var at: String?
}

/// BM25 over chunks, rolled up per meeting.
enum Ranker {
    struct Hit {
        let document: NotesDocument
        let score: Double
        /// Best chunks first.
        let chunks: [Chunk]
    }

    static func rank(_ documents: [NotesDocument], terms: [String], phrase: String) -> [Hit] {
        let k1 = 1.2, b = 0.75
        var count = 0, total = 0
        var frequency: [String: Int] = [:]
        for document in documents {
            for chunk in document.chunks {
                count += 1
                total += chunk.length
                for term in terms where chunk.terms[term] != nil { frequency[term, default: 0] += 1 }
            }
        }
        guard count > 0 else { return [] }
        let average = max(1, Double(total) / Double(count))
        let idf = frequency.mapValues { log(1 + (Double(count) - Double($0) + 0.5) / (Double($0) + 0.5)) }
        let phrase = terms.count > 1 ? Terms.fold(phrase.trimmingCharacters(in: .whitespacesAndNewlines)) : nil

        return documents.compactMap { document in
            var matched = Set<String>()
            let scored: [(Chunk, Double)] = document.chunks.compactMap { chunk in
                var score = 0.0
                for term in terms {
                    guard let tf = chunk.terms[term].map(Double.init), let idf = idf[term] else { continue }
                    matched.insert(term)
                    score += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(chunk.length) / average))
                }
                guard score > 0 else { return nil }
                if let phrase, Terms.fold(chunk.text).contains(phrase) { score *= 1.5 }
                return (chunk, score * chunk.field.weight)
            }
            .sorted { $0.1 > $1.1 }
            guard !scored.isEmpty else { return nil }
            // Best chunk counts most; more matches help with diminishing returns.
            let base = scored.prefix(3).enumerated().reduce(0) { $0 + $1.element.1 / pow(2, Double($1.offset)) }
            let coverage = Double(matched.count) / Double(terms.count)
            return Hit(document: document, score: base * (0.5 + 0.5 * coverage), chunks: scored.map(\.0))
        }
        .sorted { $0.score > $1.score }
    }
}

/// On-device sentence embeddings (NaturalLanguage; ships with macOS, no downloads) of each
/// meeting's gist. The query's language is guessed with the library's languages as hints.
struct SemanticIndex {
    private struct Entry {
        let gist: String
        let language: NLLanguage?
        var vector: [Double]?
    }

    private var entries: [Meeting.ID: Entry] = [:]
    private var models: [NLLanguage: NLEmbedding?] = [:]

    /// Closest meetings first, and how it went (reported to the caller, never hidden).
    mutating func nearest(to query: String, in documents: [NotesDocument], limit: Int) -> (ids: [Meeting.ID], status: String) {
        var languages: [NLLanguage: Double] = [:]
        for document in documents {
            let id = document.meeting.id
            if entries[id]?.gist != document.gist {
                entries[id] = Entry(gist: document.gist, language: NLLanguageRecognizer.dominantLanguage(for: document.gist))
            }
            if let language = entries[id]?.language { languages[language, default: 0] += 1 }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageHints = languages.mapValues { $0 / Double(max(1, documents.count)) }
        recognizer.processString(query)
        guard let language = recognizer.dominantLanguage else { return ([], "off: couldn't tell the query's language") }
        guard let model = model(for: language) else {
            return ([], "unavailable: no on-device sentence embedding for '\(language.rawValue)'")
        }
        guard let target = model.vector(for: query) else { return ([], "off: nothing in the query to embed") }

        var scored: [(Meeting.ID, Double)] = []
        for document in documents where entries[document.meeting.id]?.language == language {
            let id = document.meeting.id
            if entries[id]?.vector == nil { entries[id]?.vector = model.vector(for: document.gist) }
            if let vector = entries[id]?.vector { scored.append((id, Self.cosine(target, vector))) }
        }
        let ids = scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        return (ids, "on (\(language.rawValue))")
    }

    /// Forgets meetings that are gone.
    mutating func retain(_ ids: Set<Meeting.ID>) { entries = entries.filter { ids.contains($0.key) } }

    private mutating func model(for language: NLLanguage) -> NLEmbedding? {
        if let cached = models[language] { return cached }
        let model = NLEmbedding.sentenceEmbedding(for: language)
        models[language] = model
        return model
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) {
            dot += x * y
            na += x * x
            nb += y * y
        }
        return na == 0 || nb == 0 ? 0 : dot / (na.squareRoot() * nb.squareRoot())
    }
}
