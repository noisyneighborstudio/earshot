import AppKit
import os

/// Runs what the user says in command mode (dictation key + ⌃): exact matches first
/// (`CommandMatcher`), then Claude choosing from what's available, never a guess. "Make an action …" has Claude
/// draft a new action, added right away. What Claude resolves is learned when the user picks it, taps
/// Remember, or says the same thing twice; a one-off mishear is never saved.
@MainActor
@Observable
final class VoiceCommands {
    enum Outcome: Equatable {
        /// What was done, and, if Claude resolved it, the phrase learned or offered.
        case done(String, memory: Memory?)
        /// An action made by voice: the user asked for it, so it's added right away, with Undo.
        case added(name: String, learned: Learned)
        /// Claude wasn't sure; the user picks by clicking or by saying the option.
        case question(ClaudeRouter.Question, heard: String)
        case noMatch(String)
        case failed(String)
    }

    private(set) var actions: [ActionLibrary.Entry] = []
    private(set) var proposals: [ActionLibrary.Entry] = []
    private(set) var invalid: [ActionLibrary.Invalid] = []
    /// While Claude drafts an action or picks a command.
    private(set) var askingClaude = false
    /// Claude's open question, with what was said and the window it applies to.
    @ObservationIgnored private var pending: (question: ClaudeRouter.Question, utterance: String, context: CommandContext, asked: ContinuousClock.Instant)?
    /// Set by Edit on the overlay; Settings opens this action's editor.
    var editRequest: URL?
    /// When Settings › Voice Commands was last looked at; newer learned commands get a badge.
    private(set) var learnedSeen = UserDefaults.standard.object(forKey: "learnedCommandsSeen") as? Date ?? .distantPast
    var unseenLearned: Int { actions.filter { !$0.action.learned.isEmpty && $0.modified > learnedSeen }.count }

    func markLearnedSeen() {
        learnedSeen = .now
        UserDefaults.standard.set(learnedSeen, forKey: "learnedCommandsSeen")
    }
    /// As long as the overlay shows the question.
    static let questionLifetime: Duration = .seconds(20)

    enum Memory: Equatable {
        /// Saved; the toast offers Undo.
        case learned(Learned)
        /// Not saved yet; the toast offers Remember.
        case offer(Lesson)
    }

    /// A phrase Claude resolved and the action it would be saved into.
    struct Lesson: Codable, Equatable {
        let phrase: String
        let target: String
        let action: VoiceAction
    }

    /// What Claude resolved, saved as an exact phrase so next time needs no Claude. Undoable.
    struct Learned: Equatable {
        let phrase: String
        let target: String
        let file: URL
        /// The file's contents before, or nil if learning created it.
        let previous: Data?
    }

    @ObservationIgnored let library: ActionLibrary
    @ObservationIgnored private lazy var candidates = LearningCandidates(file: library.directory.appending(path: ".candidates.json"))
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

    /// The last action deleted in Settings, for Undo.
    private(set) var deleted: (name: String, file: URL, data: Data)?

    func remove(_ entry: ActionLibrary.Entry) throws {
        let data = try Data(contentsOf: entry.file)
        try FileManager.default.trashItem(at: entry.file, resultingItemURL: nil)
        deleted = (entry.action.name, entry.file, data)
        reload()
    }

    func undoDelete() throws {
        guard let deleted else { return }
        try deleted.data.write(to: deleted.file, options: .withoutOverwriting)
        self.deleted = nil
        reload()
    }

    func clearDeleted() { deleted = nil }

    /// An edited action or proposal, in place.
    func save(_ action: VoiceAction, to entry: ActionLibrary.Entry) throws {
        try library.save(action, to: entry.file)
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
        words += actions.flatMap { $0.action.phrases.map { Phrase($0).literal } }
        words += context.menu.filter(\.enabled).map(\.title)
        var seen = Set<String>()
        return words.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func run(_ utterance: String, in context: CommandContext) async -> Outcome {
        if let pending, pending.asked.duration(to: .now) < Self.questionLifetime,
           let index = Self.answer(utterance, to: pending.question) { return await answer(index) }
        pending = nil
        if let request = Self.actionRequest(utterance) { return await draft(request, context: context) }
        reload()
        let actions = actions.map(\.action)
        let apps = CommandMatcher.installedApps()
        let matcher = CommandMatcher(actions: actions, menu: context.menu, apps: apps, bundleID: context.bundleID, url: context.url)
        if let match = matcher.match(utterance) { return await perform(match, utterance: utterance, learning: .never, context: context) }
        guard let cli = ClaudeCLI.locate() else {
            return .noMatch(String(localized: "No command for “\(utterance)” in \(context.appName). Say “make an action …” to add one."))
        }
        let candidates = actions.filter { $0.applies(app: context.bundleID, url: context.url) }.map(ClaudeRouter.Candidate.action)
            + context.menu.filter(\.enabled).map(ClaudeRouter.Candidate.menu)
            + apps.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { ClaudeRouter.Candidate.app(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            + [.website]
        askingClaude = true
        let route: ClaudeRouter.Route?
        do {
            route = try await ClaudeRouter.route(utterance, candidates: candidates, appName: context.appName, cli: cli)
            askingClaude = false
        } catch {
            askingClaude = false
            log.error("command failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
        switch route {
        case .match(let match): return await perform(match, utterance: utterance, learning: .offer, context: context)
        case .ask(let question):
            pending = (question, utterance, context, .now)
            return .question(question, heard: utterance)
        case nil:
            return .noMatch(String(localized: "No command for “\(utterance)” in \(context.appName). Say “make an action …” to add one."))
        }
    }

    func dismissQuestion() { pending = nil }

    /// Runs the option picked for Claude's question, and remembers the original words for it.
    func answer(_ index: Int) async -> Outcome {
        guard let pending, pending.asked.duration(to: .now) < Self.questionLifetime + .seconds(1),
              pending.question.options.indices.contains(index) else { return .failed(String(localized: "That question has expired.")) }
        self.pending = nil
        return await perform(pending.question.options[index].match, utterance: pending.utterance, learning: .now, context: pending.context)
    }

    /// Which option a spoken answer names: "the beta one", "nightly", "second", "two".
    nonisolated static func answer(_ utterance: String, to question: ClaudeRouter.Question) -> Int? {
        let words = Set(Phrase.normalize(utterance).split(separator: " ").map(String.init))
        let ordinals = [["first", "one", "1"], ["second", "two", "2"], ["third", "three", "3"], ["fourth", "four", "4"]]
        let byOrdinal = ordinals.prefix(question.options.count).indices.filter { !words.isDisjoint(with: ordinals[$0]) }
        if byOrdinal.count == 1 { return byOrdinal[0] }
        // Words that tell this option apart from the others.
        let labels = question.options.map { Set(Phrase.normalize($0.label).split(separator: " ").map(String.init)) }
        let hits = labels.indices.filter { i in
            let distinct = labels[i].subtracting(labels.indices.filter { $0 != i }.reduce(into: Set<String>()) { $0.formUnion(labels[$1]) })
            return !distinct.isDisjoint(with: words)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// `now`: the user picked it from Claude's question. `offer`: Claude picked it; saved on the second time.
    enum Learning { case never, offer, now }

    private func perform(_ match: CommandMatch, utterance: String, learning: Learning, context: CommandContext) async -> Outcome {
        do {
            let done = try await perform(match, context: context)
            guard learning != .never, let lesson = lesson(utterance, as: match, context: context) else { return .done(done, memory: nil) }
            do {
                if learning == .now || candidates.recordRepeat(lesson) {
                    return .done(done, memory: try remember(lesson).map(Memory.learned))
                }
                return .done(done, memory: .offer(lesson))
            } catch {
                log.error("couldn't learn “\(utterance)”: \(error.localizedDescription)")
                return .done(done, memory: nil)
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
        case .openURL(let url, nil):
            try open(url)
            return String(localized: "Opened \(url.host() ?? url.absoluteString)")
        case .openURL(let url, let browser?):
            try await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: .init())
            return String(localized: "Opened \(url.host() ?? url.absoluteString) in \(browser.deletingPathExtension().lastPathComponent)")
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

    /// What saving the utterance for Claude's choice would add. Commands with parameters, or URLs in a
    /// specific browser, aren't learned.
    func lesson(_ utterance: String, as match: CommandMatch, context: CommandContext) -> Lesson? {
        let phrase = Phrase.normalize(utterance)
        guard !phrase.isEmpty else { return nil }
        let action: VoiceAction, target: String
        switch match {
        case .openApp(_, let url):
            target = url.deletingPathExtension().lastPathComponent
            action = VoiceAction(name: String(localized: "Open \(target)"), say: [], steps: [.openApp(target)])
        case .menu(let item):
            // A fragment several menu items share ("vertically") is a mishear, not a name for this one.
            let shared = context.menu.filter { Phrase.normalize($0.title).contains(phrase) }.count
            guard shared < 2 || Phrase.normalize(item.title) == phrase else { return nil }
            target = item.display
            action = VoiceAction(name: item.title, say: [], when: .init(app: context.bundleID), steps: [.menu(item.path)])
        case .action(let chosen, let parameters) where parameters.isEmpty:
            target = chosen.name
            action = chosen
        case .openURL(let url, nil):
            target = url.host() ?? url.absoluteString
            action = VoiceAction(name: String(localized: "Open \(target)"), say: [], steps: [.openURL(url.absoluteString)])
        case .action, .openURL:
            return nil
        }
        return Lesson(phrase: phrase, target: target, action: action)
    }

    /// Saves the lesson's phrase as learned: into the action with the same steps and scope, else a new one.
    /// Nil if that action already answers to it.
    func remember(_ lesson: Lesson) throws -> Learned? {
        reload()
        candidates.remove(lesson)
        let action = lesson.action
        if let existing = actions.first(where: { $0.action.steps == action.steps && $0.action.when == action.when }) {
            guard existing.action.match(lesson.phrase) == nil else { return nil }
            let previous = try Data(contentsOf: existing.file)
            var updated = existing.action
            updated.learned.append(lesson.phrase)
            try library.save(updated, to: existing.file)
            reload()
            return Learned(phrase: lesson.phrase, target: lesson.target, file: existing.file, previous: previous)
        }
        var new = action
        new.say = []
        new.learned = [lesson.phrase]
        let file = try library.add(new)
        reload()
        return Learned(phrase: lesson.phrase, target: lesson.target, file: file, previous: nil)
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
            let file = try library.add(action)
            reload()
            return .added(name: action.name, learned: Learned(phrase: action.phrases[0], target: action.name, file: file, previous: nil))
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

/// Phrases Claude resolved once, waiting to be said again before they're saved. Expire after 30 days.
struct LearningCandidates {
    let file: URL
    private struct Candidate: Codable {
        let lesson: VoiceCommands.Lesson
        let date: Date
    }

    static let lifetime: TimeInterval = 30 * 24 * 3600

    /// True if the same phrase already led to the same action recently (then it's removed); else records it.
    func recordRepeat(_ lesson: VoiceCommands.Lesson, now: Date = .now) -> Bool {
        var list = load(now: now)
        if list.contains(where: { Self.same($0.lesson, lesson) }) {
            write(list.filter { !Self.same($0.lesson, lesson) })
            return true
        }
        list.append(Candidate(lesson: lesson, date: now))
        write(list)
        return false
    }

    func remove(_ lesson: VoiceCommands.Lesson) {
        let list = load(now: .now)
        if list.contains(where: { Self.same($0.lesson, lesson) }) { write(list.filter { !Self.same($0.lesson, lesson) }) }
    }

    private static func same(_ a: VoiceCommands.Lesson, _ b: VoiceCommands.Lesson) -> Bool {
        a.phrase == b.phrase && a.action.steps == b.action.steps && a.action.when == b.action.when
    }

    private func load(now: Date) -> [Candidate] {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Candidate].self, from: data) else { return [] }
        return list.filter { now.timeIntervalSince($0.date) < Self.lifetime }
    }

    private func write(_ list: [Candidate]) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(list).write(to: file, options: .atomic)
        } catch {
            Logger(subsystem: "studio.noisyneighbor.earshot", category: "commands").error("couldn't save learning candidates: \(error.localizedDescription)")
        }
    }
}
