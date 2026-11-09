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

        var line: String {
            switch self {
            case .action(let action): "Action: \(action.name) (says: \(action.say.joined(separator: " / ")))"
            case .menu(let item): "Menu: \(item.display)"
            case .app(let name, _): "Open app: \(name)"
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
    }

    static func route(_ utterance: String, candidates: [Candidate], appName: String, cli: ClaudeCLI) async throws -> CommandMatch? {
        guard !candidates.isEmpty else { return nil }
        let reply = try await cli.run(
            model: "claude-haiku-5-5", effort: "low", system: system,
            input: input(utterance, candidates: candidates, appName: appName), timeout: .seconds(30))
        let result = match(try decode(reply), candidates: candidates)
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
        // Compared normalized, so a stray dash, quotes or period in the copy don't lose the match.
        guard let line = choice.command.map(Phrase.normalize), !line.isEmpty,
              let candidate = candidates.first(where: { Phrase.normalize($0.line) == line })
                ?? candidates.first(where: { Phrase.normalize($0.shortLine) == line }) else { return nil }
        switch candidate {
        case .menu(let item): return .menu(item)
        case .app(let name, let url): return .openApp(name: name, url: url)
        case .action(let action):
            let names = action.say.lazy.map { Phrase($0).parameters }.first { !$0.isEmpty } ?? []
            let values = choice.parameters ?? []
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
        """
}
