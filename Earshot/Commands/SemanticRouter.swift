import Foundation
import FoundationModels

/// When no phrase matches exactly, the on-device model picks among this window's commands (its
/// menu items and applicable actions), or none. It only chooses from the list, never invents one.
@MainActor
enum SemanticRouter {
    @Generable
    struct Choice {
        @Guide(description: "The number of the command the user asked for, or 0 if none clearly fits.")
        var number: Int
        @Guide(description: "For a command with {parameters}: their values in order, taken from what the user said. Otherwise empty.")
        var parameters: [String]
    }

    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    static func route(_ utterance: String, actions: [VoiceAction], menu: [MenuItem], appName: String) async throws -> CommandMatch? {
        let items = menu.filter(\.enabled)
        let commands = actions.map { "\($0.name) — says: \($0.say.joined(separator: " / "))" }
            + items.map { "Menu: \($0.display)" }
        guard !commands.isEmpty else { return nil }
        let list = commands.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You map a spoken request to one command from a numbered list of what's available in the user's \
            frontmost app. Choose a command only if it clearly does what was asked; otherwise answer 0. \
            Never pick something merely related.
            """)
        let choice = try await session.respond(
            to: "Frontmost app: \(appName)\nCommands:\n\(list)\n\nThe user said: \"\(utterance)\"",
            generating: Choice.self
        ).content
        let index = choice.number - 1
        guard commands.indices.contains(index) else { return nil }
        if index >= actions.count { return .menu(items[index - actions.count]) }
        let action = actions[index]
        let names = action.say.lazy.map { Phrase($0).parameters }.first { !$0.isEmpty } ?? []
        guard names.count == choice.parameters.count || names.isEmpty else { return nil }
        return .action(action, parameters: Dictionary(uniqueKeysWithValues: zip(names, choice.parameters)))
    }
}
