import Foundation
import os

/// When no phrase matches exactly, Claude picks among what's available right now (this window's
/// actions and menu items, and installed apps), or nothing. It only chooses from the list, and it
/// can see past speech-recognition mistakes ("open high term" → iTerm).
enum ClaudeRouter {
    enum Candidate: Equatable {
        case action(VoiceAction)
        case menu(MenuItem)
        case app(name: String, url: URL)
        /// Any site Claude knows the address of: "open hacker news in the browser".
        case website

        var line: String {
            switch self {
            case .website: "Open website"
            case .action(let action): "Action: \(action.name) (says: \(action.phrases.joined(separator: " / ")))"
            case .menu(let item): "Menu: \(item.display)"
            case .app(let name, _): "Open app: \(name)"
            }
        }

        /// For a follow-up question's buttons.
        var label: String {
            switch self {
            case .action(let action): action.name
            case .menu(let item): item.display
            case .app(let name, _): name
            case .website: String(localized: "Website")
            }
        }

        /// Claude sometimes copies only an action's name, without its phrases.
        var shortLine: String {
            if case .action(let action) = self { "Action: \(action.name)" } else { line }
        }
    }

    /// The chosen line, copied verbatim; text, not a number, so long lists can't be miscounted.
    struct Choice: Decodable, Equatable {
        let command: String?
        let parameters: [String]?
        /// When it's unsure: a short question and the lines it might be.
        var question: String? = nil
        var options: [String]? = nil
    }

    enum Route: Equatable {
        case match(CommandMatch)
        case ask(Question)
    }

    struct Question: Equatable {
        let text: String
        let options: [(label: String, match: CommandMatch)]

        static func == (a: Self, b: Self) -> Bool {
            a.text == b.text && a.options.map(\.label) == b.options.map(\.label) && a.options.map(\.match) == b.options.map(\.match)
        }
    }

    static func route(_ utterance: String, candidates: [Candidate], appName: String, cli: ClaudeCLI) async throws -> Route? {
        guard !candidates.isEmpty else { return nil }
        let reply = try await cli.run(
            model: "claude-haiku-5-5", effort: "low", system: system,
            input: input(utterance, candidates: candidates, appName: appName), timeout: .seconds(30))
        let choice = try decode(reply)
        let result = match(choice, candidates: candidates).map(Route.match) ?? question(choice, candidates: candidates).map(Route.ask)
        Logger(subsystem: "studio.noisyneighbor.earshot", category: "commands").notice(
            "heard “\(utterance, privacy: .public)”, \(candidates.count) candidates; Claude: \(reply, privacy: .public) → \(result == nil ? "no match" : "matched")")
        return result
    }

    static func input(_ utterance: String, candidates: [Candidate], appName: String) -> String {
        let list = candidates.map { "- \($0.line)" }.joined(separator: "\n")
        return "Frontmost app: \(appName)\nCommands:\n\(list)\n\nThe user said: \"\(utterance)\""
    }

    static func decode(_ reply: String) throws -> Choice {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
              let choice = try? JSONDecoder().decode(Choice.self, from: Data(reply[start...end].utf8))
        else { throw ActionError(String(localized: "Claude's answer wasn't a command choice.")) }
        return choice
    }

    /// The chosen command, or nil for none or a line that isn't on the list.
    static func match(_ choice: Choice, candidates: [Candidate]) -> CommandMatch? {
        choice.command.flatMap { candidate($0, in: candidates) }.flatMap { resolve($0, parameters: choice.parameters) }
    }

    /// Claude's follow-up question, if it asked one with at least two options that are on the list.
    static func question(_ choice: Choice, candidates: [Candidate]) -> Question? {
        guard let text = choice.question?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let options = (choice.options ?? []).compactMap { line -> (label: String, match: CommandMatch)? in
            guard let candidate = candidate(line, in: candidates),
                  let match = resolve(candidate, parameters: choice.parameters) else { return nil }
            return (candidate.label, match)
        }
        return options.count >= 2 ? Question(text: text, options: Array(options.prefix(4))) : nil
    }

    // Compared normalized, so a stray dash, quotes or period in the copy don't lose the match.
    private static func candidate(_ line: String, in candidates: [Candidate]) -> Candidate? {
        let line = Phrase.normalize(line)
        guard !line.isEmpty else { return nil }
        return candidates.first { Phrase.normalize($0.line) == line } ?? candidates.first { Phrase.normalize($0.shortLine) == line }
    }

    private static func resolve(_ candidate: Candidate, parameters: [String]?) -> CommandMatch? {
        switch candidate {
        case .menu(let item): return .menu(item)
        case .app(let name, let url): return .openApp(name: name, url: url)
        case .website:
            guard let value = parameters?.first, parameters?.count == 1, let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil else { return nil }
            return .openURL(url)
        case .action(let action):
            let names = action.phrases.lazy.map { Phrase($0).parameters }.first { !$0.isEmpty } ?? []
            let values = parameters ?? []
            guard names.count == values.count else { return nil }
            return .action(action, parameters: Dictionary(uniqueKeysWithValues: zip(names, values)))
        }
    }

    /// Model-facing, so English.
    static let system = """
        You route a spoken command to one line from a list of what's available on the user's Mac right now. \
        The words come from speech recognition and may be misheard, especially names: match by meaning and by \
        sound ("open high term" means "Open app: iTerm"). Choose a line only if it clearly does what was asked; \
        otherwise choose none. Never pick something merely related.
        Reply with ONLY JSON: {"command": "<the chosen line, copied exactly, without the leading dash>", \
        "parameters": ["…"]}, or {"command": null} for none. parameters: for an Action whose phrases have \
        {placeholders}, their values in order, from what the user said; otherwise [].
        "Open website" opens any site: its one parameter is the site's full https URL, if you know it.
        If it could mean two to four lines and you can't tell which, ask instead: {"question": "<short question>", \
        "options": ["<line>", "<line>"], "parameters": [...]}. Only ask when it's genuinely ambiguous.
        """
}
