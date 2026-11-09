import Foundation

/// A voice command: phrases that trigger it, where it applies, and the steps it runs. One JSON file
/// per action in Earshot/Actions; agents and "make an action" write to Actions/Proposed until the
/// user approves them in Settings.
///
///     { "name": "Bookmark page", "say": ["save this", "bookmark this"],
///       "when": { "app": "com.apple.Safari" }, "steps": [{ "keystroke": "cmd+d" }] }
struct VoiceAction: Codable, Equatable, Sendable {
    var name: String
    /// Example phrases. `{name}` captures a parameter, e.g. "search hacker news for {query}".
    var say: [String]
    var when: Scope?
    var steps: [Step]

    struct Scope: Codable, Equatable, Sendable {
        /// Bundle identifier of the frontmost app, e.g. com.apple.Safari.
        var app: String?
        /// Glob matched against the frontmost window's URL, e.g. *://news.ycombinator.com/*.
        var url: String?
    }

    enum Step: Equatable, Sendable {
        case openApp(String)
        /// `{param}`, `{url}` and `{app}` are replaced, URL-encoded.
        case openURL(String)
        /// e.g. "cmd+shift+d", "return", "f5".
        case keystroke(String)
        /// Menu titles from the menu bar down, e.g. ["File", "Export as PDF…"].
        case menu([String])
        /// A Shortcuts.app shortcut, by name.
        case shortcut(String)
    }

    /// Placeholders the frontmost window provides, beside the phrase's own `{params}`.
    static let contextPlaceholders: Set<String> = ["url", "app"]

    /// Problems that make the action unusable, for the user or the agent that wrote it.
    func problems() -> [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("`name` is empty.") }
        if say.isEmpty { problems.append("`say` needs at least one phrase.") }
        if steps.isEmpty { problems.append("`steps` needs at least one step.") }
        for phrase in say where Phrase(phrase).literal.isEmpty {
            problems.append("Phrase \"\(phrase)\" has no words to match.")
        }
        let params = Set(say.flatMap { Phrase($0).parameters }).union(Self.contextPlaceholders)
        for case .openURL(let template) in steps {
            for placeholder in Phrase.placeholders(in: template) where !params.contains(placeholder) {
                problems.append("{\(placeholder)} in \(template) isn't captured by any phrase.")
            }
        }
        for case .keystroke(let keys) in steps where Keystroke(keys) == nil {
            problems.append("Keystroke \"\(keys)\" isn't recognized.")
        }
        if when?.app?.isEmpty == true || when?.url?.isEmpty == true { problems.append("`when` has an empty value.") }
        return problems
    }

    /// 2 = app and URL, 1 = one of them, 0 = everywhere. The most specific match wins.
    var specificity: Int { (when?.app == nil ? 0 : 1) + (when?.url == nil ? 0 : 1) }

    func applies(app bundleID: String, url: String?) -> Bool {
        if let app = when?.app, app.caseInsensitiveCompare(bundleID) != .orderedSame { return false }
        if let pattern = when?.url {
            guard let url, fnmatch(pattern, url, FNM_CASEFOLD) == 0 else { return false }
        }
        return true
    }

    /// Whether both could apply to the same window at the same specificity, so neither wins.
    func overlaps(_ other: VoiceAction) -> Bool {
        guard specificity == other.specificity else { return false }
        return when?.app?.lowercased() == other.when?.app?.lowercased() && when?.url == other.when?.url
    }

    /// The utterance's parameters if one of `say` matches it.
    func match(_ utterance: String) -> [String: String]? {
        let normalized = Phrase.normalize(utterance)
        for phrase in say {
            if let params = Phrase(phrase).match(normalized) { return params }
        }
        return nil
    }
}

extension VoiceAction.Step: Codable {
    private enum Key: String, CodingKey, CaseIterable {
        case openApp = "open_app", openURL = "open_url", keystroke, menu, shortcut
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A step has exactly one of: \(Key.allCases.map(\.rawValue).joined(separator: ", "))."))
        }
        switch key {
        case .openApp: self = .openApp(try container.decode(String.self, forKey: key))
        case .openURL: self = .openURL(try container.decode(String.self, forKey: key))
        case .keystroke: self = .keystroke(try container.decode(String.self, forKey: key))
        case .menu: self = .menu(try container.decode([String].self, forKey: key))
        case .shortcut: self = .shortcut(try container.decode(String.self, forKey: key))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .openApp(let app): try container.encode(app, forKey: .openApp)
        case .openURL(let url): try container.encode(url, forKey: .openURL)
        case .keystroke(let keys): try container.encode(keys, forKey: .keystroke)
        case .menu(let path): try container.encode(path, forKey: .menu)
        case .shortcut(let name): try container.encode(name, forKey: .shortcut)
        }
    }
}

/// A `say` phrase: literal words plus `{param}` captures.
struct Phrase {
    private let tokens: [Token]
    private enum Token: Equatable { case word(String), param(String) }

    init(_ text: String) {
        var tokens: [Token] = []
        for word in text.split(separator: " ") {
            let word = String(word)
            if word.hasPrefix("{"), word.hasSuffix("}"), word.count > 2 {
                tokens.append(.param(String(word.dropFirst().dropLast())))
            } else {
                tokens += Self.normalize(word).split(separator: " ").map { .word(String($0)) }
            }
        }
        self.tokens = tokens
    }

    var parameters: [String] { tokens.compactMap { if case .param(let name) = $0 { name } else { nil } } }
    /// The phrase's words without its parameters.
    var literal: String { tokens.compactMap { if case .word(let word) = $0 { word } else { nil } }.joined(separator: " ") }
    /// An utterance the phrase matches, with "x" for each parameter.
    var sample: String { tokens.map { if case .word(let word) = $0 { word } else { "x" } }.joined(separator: " ") }

    /// Parameters for a normalized utterance, or nil. Each parameter takes at least one word.
    func match(_ normalized: String) -> [String: String]? {
        let words = normalized.split(separator: " ").map(String.init)
        return Self.match(tokens[...], words[...], [:])
    }

    private static func match(_ tokens: ArraySlice<Token>, _ words: ArraySlice<String>, _ bound: [String: String]) -> [String: String]? {
        guard let token = tokens.first else { return words.isEmpty ? bound : nil }
        switch token {
        case .word(let word):
            guard words.first == word else { return nil }
            return match(tokens.dropFirst(), words.dropFirst(), bound)
        case .param(let name):
            guard !words.isEmpty else { return nil }
            // Shortest capture first, so literal words after it anchor the split.
            for end in words.startIndex + 1...words.endIndex {
                var next = bound
                next[name] = words[words.startIndex..<end].joined(separator: " ")
                if let result = match(tokens.dropFirst(), words[end...], next) { return result }
            }
            return nil
        }
    }

    /// Lowercased, without accents or punctuation, single-spaced: what's compared.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    static func placeholders(in template: String) -> [String] {
        template.matches(of: /\{([A-Za-z_][A-Za-z0-9_]*)\}/).map { String($0.output.1) }
    }

    /// Fills `{name}` placeholders, URL-encoding each value.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var result = template
        for (name, value) in values {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
            result = result.replacingOccurrences(of: "{\(name)}", with: encoded)
        }
        return result
    }
}

extension CharacterSet {
    /// Query-value characters: urlQueryAllowed minus the separators that would split it.
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
}

/// A parsed keystroke: "cmd+shift+d", "return", "f5".
struct Keystroke: Equatable, Sendable {
    enum Modifier: String, CaseIterable, Sendable { case command, shift, option, control }
    let modifiers: Set<Modifier>
    /// A single character, or a named key: return, tab, space, escape, delete, left, right, up, down, f1…f12.
    let key: String

    static let namedKeys = Set(["return", "tab", "space", "escape", "delete", "left", "right", "up", "down"]
        + (1...12).map { "f\($0)" })

    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var modifiers: Set<Modifier> = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            default: return nil
            }
        }
        let aliases = ["enter": "return", "esc": "escape", "backspace": "delete"]
        let key = aliases[last] ?? last
        guard key.count == 1 || Self.namedKeys.contains(key) else { return nil }
        self.modifiers = modifiers
        self.key = key
    }
}

/// The Actions folder: approved actions, and proposals waiting for the user.
struct ActionLibrary: Sendable {
    let directory: URL
    var proposed: URL { directory.appending(path: "Proposed") }

    struct Entry: Identifiable, Sendable {
        let file: URL
        let action: VoiceAction
        var id: URL { file }
    }

    struct Invalid: Identifiable, Sendable {
        let file: URL
        let problem: String
        var id: URL { file }
    }

    func load(proposals: Bool = false) -> (actions: [Entry], invalid: [Invalid]) {
        let folder = proposals ? proposed : directory
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var actions: [Entry] = [], invalid: [Invalid] = []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let action = try JSONDecoder().decode(VoiceAction.self, from: Data(contentsOf: file))
                if let problem = action.problems().first {
                    invalid.append(Invalid(file: file, problem: problem))
                } else {
                    actions.append(Entry(file: file, action: action))
                }
            } catch {
                invalid.append(Invalid(file: file, problem: Self.describe(error)))
            }
        }
        return (actions, invalid)
    }

    /// Writes a proposal; never overwrites one.
    @discardableResult
    func propose(_ action: VoiceAction) throws -> URL {
        try create(action, in: proposed)
    }

    /// Adds an approved action, e.g. one learned from a command Claude resolved.
    @discardableResult
    func add(_ action: VoiceAction) throws -> URL {
        try create(action, in: directory)
    }

    /// Replaces an action's file (editing, or adding a learned phrase).
    func save(_ action: VoiceAction, to file: URL) throws {
        if let problem = action.problems().first { throw ActionError(problem) }
        try Self.encoder.encode(action).write(to: file, options: .atomic)
    }

    private func create(_ action: VoiceAction, in folder: URL) throws -> URL {
        if let problem = action.problems().first { throw ActionError(problem) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let slug = Phrase.normalize(action.name).replacingOccurrences(of: " ", with: "-").prefix(48)
        let base = slug.isEmpty ? "action" : String(slug)
        var file = folder.appending(path: "\(base).json")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appending(path: "\(base)-\(n).json")
            n += 1
        }
        try Self.encoder.encode(action).write(to: file, options: .withoutOverwriting)
        return file
    }

    /// Moves a proposal into the approved actions.
    func approve(_ proposal: URL) throws {
        var target = directory.appending(path: proposal.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(path: "\(proposal.deletingPathExtension().lastPathComponent)-\(n).json")
            n += 1
        }
        try FileManager.default.moveItem(at: proposal, to: target)
    }

    /// Phrases of `action` that an approved action at the same scope already answers to.
    func collisions(_ action: VoiceAction, with approved: [Entry]) -> [String] {
        approved.filter { $0.action.overlaps(action) }.flatMap { existing in
            action.say.filter { phrase in
                let new = Phrase(phrase)
                return existing.action.match(new.sample) != nil
                    || existing.action.say.contains { new.match(Phrase($0).sample) != nil }
            }.map { "\"\($0)\" (\(existing.action.name))" }
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "Missing `\(key.stringValue)`."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context):
            context.codingPath.isEmpty ? context.debugDescription
                : "`\(context.codingPath.map(\.stringValue).joined(separator: "."))`: \(context.debugDescription)"
        default: error.localizedDescription
        }
    }
}

struct ActionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension EarshotData {
    static var actions: ActionLibrary { ActionLibrary(directory: directory.appending(path: "Actions")) }
}
