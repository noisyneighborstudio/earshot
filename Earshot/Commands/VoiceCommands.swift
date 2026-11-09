import AppKit
import os

/// Runs what the user says in command mode (dictation key + ⌃): exact matches first
/// (`CommandMatcher`), then Claude choosing from what's available, never a guess. "Make an action …" has Claude
/// draft a new action, which waits in Settings until the user approves it.
@MainActor
@Observable
final class VoiceCommands {
    enum Outcome: Equatable {
        /// What was done, and the phrase learned from it if Claude had to resolve it.
        case done(String, learned: Learned?)
        case proposed(String)
        case noMatch(String)
        case failed(String)
    }

    private(set) var actions: [ActionLibrary.Entry] = []
    private(set) var proposals: [ActionLibrary.Entry] = []
    private(set) var invalid: [ActionLibrary.Invalid] = []
    /// While Claude drafts an action or picks a command.
    private(set) var askingClaude = false

    /// What Claude resolved, saved as an exact phrase so next time needs no Claude. Undoable.
    struct Learned: Equatable {
        let phrase: String
        let target: String
        let file: URL
        /// The file's contents before, or nil if learning created it.
        let previous: Data?
    }

    @ObservationIgnored let library: ActionLibrary
    @ObservationIgnored private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "commands")

    init(library: ActionLibrary = EarshotData.actions) {
        self.library = library
        reload()
    }

    /// Re-reads the Actions folder; agents may have added proposals since.
    func reload() {
        let approved = library.load(), proposed = library.load(proposals: true)
        actions = approved.actions
        proposals = proposed.actions
        invalid = approved.invalid + proposed.invalid
    }

    func approve(_ proposal: ActionLibrary.Entry) throws {
        try library.approve(proposal.file)
        reload()
    }

    func remove(_ entry: ActionLibrary.Entry) throws {
        try FileManager.default.trashItem(at: entry.file, resultingItemURL: nil)
        reload()
    }

    func collisions(_ proposal: ActionLibrary.Entry) -> [String] { library.collisions(proposal.action, with: actions) }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: library.proposed, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([library.directory])
    }

    // MARK: Running

    /// Words the recognizer should expect in command mode: app names, action phrases, menu titles.
    func vocabulary(for context: CommandContext) -> [String] {
        var words = CommandMatcher.installedApps().values.map { $0.deletingPathExtension().lastPathComponent }
        words += actions.flatMap { $0.action.say.map { Phrase($0).literal } }
        words += context.menu.filter(\.enabled).map(\.title)
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func run(_ utterance: String, in context: CommandContext) async -> Outcome {
        if let request = Self.actionRequest(utterance) { return await draft(request, context: context) }
        reload()
        let actions = actions.map(\.action)
        let apps = CommandMatcher.installedApps()
        let matcher = CommandMatcher(actions: actions, menu: context.menu, apps: apps, bundleID: context.bundleID, url: context.url)
        do {
            var match = matcher.match(utterance)
            let viaClaude = match == nil
            if match == nil, let cli = ClaudeCLI.locate() {
                let candidates = actions.filter { $0.applies(app: context.bundleID, url: context.url) }.map(ClaudeRouter.Candidate.action)
                    + context.menu.filter(\.enabled).map(ClaudeRouter.Candidate.menu)
                    + apps.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
                        .map { ClaudeRouter.Candidate.app(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
                askingClaude = true
                defer { askingClaude = false }
                match = try await ClaudeRouter.route(utterance, candidates: candidates, appName: context.appName, cli: cli)
            }
            guard let match else {
                return .noMatch(String(localized: "No command for “\(utterance)” in \(context.appName). Say “make an action …” to add one."))
            }
            let done = try await perform(match, context: context)
            guard viaClaude else { return .done(done, learned: nil) }
            do {
                return .done(done, learned: try learn(utterance, as: match, context: context))
            } catch {
                log.error("couldn't learn “\(utterance)”: \(error.localizedDescription)")
                return .done(done, learned: nil)
            }
        } catch {
            log.error("command failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Returns what was done, for the overlay.
    private func perform(_ match: CommandMatch, context: CommandContext) async throws -> String {
        switch match {
        case .menu(let item):
            try context.press(item)
            return item.display
        case .openApp(_, let url):
            try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return String(localized: "Opened \(url.deletingPathExtension().lastPathComponent)")
        case .openURL(let url):
            try open(url)
            return String(localized: "Opened \(url.host() ?? url.absoluteString)")
        case .action(let action, let parameters):
            var values = parameters
            values["app"] = context.bundleID
            values["url"] = context.url ?? ""
            for step in action.steps { try await run(step, values: values, context: context) }
            return action.name
        }
    }

    private func run(_ step: VoiceAction.Step, values: [String: String], context: CommandContext) async throws {
        switch step {
        case .openApp(let name):
            let apps = CommandMatcher.installedApps()
            if let url = apps[Phrase.normalize(name)] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } else {
                throw ActionError(String(localized: "Couldn't find the app “\(name)”."))
            }
        case .openURL(let template):
            let filled = Phrase.fill(template, values)
            guard let url = URL(string: filled) else { throw ActionError(String(localized: "Not a valid URL: \(filled)")) }
            try open(url)
        case .keystroke(let keys):
            guard let keystroke = Keystroke(keys) else { throw ActionError(String(localized: "Unknown keystroke “\(keys)”.")) }
            try KeySender.press(keystroke)
        case .menu(let path):
            let wanted = path.map(Phrase.normalize)
            guard let item = context.menu.first(where: { $0.path.map(Phrase.normalize) == wanted }) else {
                throw ActionError(String(localized: "\(context.appName) has no menu item \(path.joined(separator: " › "))."))
            }
            guard item.enabled else { throw ActionError(String(localized: "\(item.display) is unavailable right now.")) }
            try context.press(item)
        case .shortcut(let name):
            let output = try await Subprocess.run(URL(filePath: "/usr/bin/shortcuts"), ["run", name], timeout: .seconds(120))
            guard output.status == 0 else { throw ActionError(String(localized: "Shortcut “\(name)”: \(output.message)")) }
        }
    }

    private func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw ActionError(String(localized: "Couldn't open \(url.absoluteString).")) }
    }

    // MARK: Learning

    /// Saves the utterance as a phrase for what Claude chose: added to an action with the same steps
    /// and scope if there is one, else a new action. Commands with parameters or URLs aren't learned.
    func learn(_ utterance: String, as match: CommandMatch, context: CommandContext) throws -> Learned? {
        let phrase = Phrase.normalize(utterance)
        guard !phrase.isEmpty else { return nil }
        let action: VoiceAction, target: String
        switch match {
        case .openApp(_, let url):
            target = url.deletingPathExtension().lastPathComponent
            action = VoiceAction(name: String(localized: "Open \(target)"), say: [phrase], steps: [.openApp(target)])
        case .menu(let item):
            target = item.display
            action = VoiceAction(name: String(localized: "\(item.title) in \(context.appName)"), say: [phrase],
                                 when: .init(app: context.bundleID), steps: [.menu(item.path)])
        case .action(let chosen, let parameters) where parameters.isEmpty:
            target = chosen.name
            action = chosen
        case .action, .openURL:
            return nil
        }
        reload()
        if let existing = actions.first(where: { $0.action.steps == action.steps && $0.action.when == action.when }) {
            let previous = try Data(contentsOf: existing.file)
            var updated = existing.action
            updated.say.append(phrase)
            try library.save(updated, to: existing.file)
            reload()
            return Learned(phrase: phrase, target: target, file: existing.file, previous: previous)
        }
        let file = try library.add(action)
        reload()
        return Learned(phrase: phrase, target: target, file: file, previous: nil)
    }

    func forget(_ learned: Learned) throws {
        if let previous = learned.previous {
            try previous.write(to: learned.file, options: .atomic)
        } else {
            try FileManager.default.removeItem(at: learned.file)
        }
        reload()
    }

    // MARK: Making actions

    /// The description after "make an action", or nil if this isn't a request for one.
    nonisolated static func actionRequest(_ utterance: String) -> String? {
        let text = Phrase.normalize(utterance)
        for prefix in ["make an action", "make a new action", "create an action", "add an action", "new action",
                       "make a command", "create a command", "add a command", "new command"] where text == prefix || text.hasPrefix(prefix + " ") {
            let words = utterance.split(separator: " ", omittingEmptySubsequences: true)
            let rest = words.dropFirst(prefix.split(separator: " ").count).joined(separator: " ")
            return rest.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        }
        return nil
    }

    private func draft(_ request: String, context: CommandContext) async -> Outcome {
        guard !request.isEmpty else {
            return .failed(String(localized: "Say what the action should do, e.g. “make an action: when I say standup, open Zoom”."))
        }
        guard let cli = ClaudeCLI.locate() else { return .failed(ClaudeCLIError.notFound.localizedDescription) }
        askingClaude = true
        defer { askingClaude = false }
        do {
            let reply = try await cli.run(
                model: "claude-sonnet-5-5", effort: "low", system: Self.draftingPrompt,
                input: Self.draftingInput(request, context: context), timeout: .seconds(90))
            let action = try Self.decodeDraft(reply)
            try library.propose(action)
            reload()
            return .proposed(String(localized: "“\(action.name)” is ready to review in Settings › Voice Commands."))
        } catch {
            log.error("drafting an action failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func decodeDraft(_ reply: String) throws -> VoiceAction {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}") else {
            throw ActionError(String(localized: "Claude didn't return an action."))
        }
        do {
            return try JSONDecoder().decode(VoiceAction.self, from: Data(reply[start...end].utf8))
        } catch {
            throw ActionError(String(localized: "Claude's action was malformed: \(ActionLibrary.describe(error))"))
        }
    }

    private static func draftingInput(_ request: String, context: CommandContext) -> String {
        var lines = ["Request: \(request)", "Frontmost app: \(context.appName) (\(context.bundleID))"]
        if let url = context.url { lines.append("Frontmost URL: \(url)") }
        let menu = context.menu.filter(\.enabled).prefix(300).map { "- " + $0.path.joined(separator: " > ") }
        if !menu.isEmpty { lines.append("Its menu items:\n" + menu.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    /// Model-facing, so English.
    static let draftingPrompt = """
        You write voice-command actions for NN Earshot, a Mac app. The user describes an action; reply with \
        ONLY one JSON object, no prose or code fences:

        {"name": "Short title", "say": ["phrase", "another phrase with {param}"], "when": {"app": "bundle.id", "url": "*://host/*"}, "steps": [ ... ]}

        - say: 1-4 short spoken phrases, lowercase, no punctuation. {name} captures words as a parameter, \
        e.g. "search github for {query}".
        - when (optional): limit to an app (bundle id) and/or a URL glob. Use the frontmost app only when the \
        user implies it ("in Safari", "here", "on this site"); omit "when" for a global action.
        - steps, in order, each an object with exactly one key:
          {"open_app": "App Name"}  {"open_url": "https://…{param}…"}  {"keystroke": "cmd+shift+d"}
          {"menu": ["Menu", "Item"]}  {"shortcut": "Shortcuts app shortcut name"}
          open_url may use {param}s from say, plus {url} (the frontmost page) and {app}; values are URL-encoded.
          keystroke: modifiers cmd/shift/opt/ctrl joined with + and one key (a character, return, tab, space, \
        escape, delete, arrows, f1-f12). menu: exact titles from the app's menu items listed below.
        - Prefer menu items over keystrokes when one fits. Use only what the user asked for.
        """
}
