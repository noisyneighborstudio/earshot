import Foundation
import Testing
@testable import Earshot

private func action(_ json: String) throws -> VoiceAction {
    try JSONDecoder().decode(VoiceAction.self, from: Data(json.utf8))
}

struct PhraseTests {
    @Test func normalizesCasePunctuationAndAccents() {
        #expect(Phrase.normalize("  Save this, please! ") == "save this please")
        #expect(Phrase.normalize("Café — Export as PDF…") == "cafe export as pdf")
    }

    @Test func capturesParametersAnchoredByLiteralWords() {
        let phrase = Phrase("search {site} for {query}")
        #expect(phrase.match("search hacker news for rust async") == ["site": "hacker news", "query": "rust async"])
        #expect(phrase.match("search for rust") == nil)
        #expect(Phrase("standup").match("standup now") == nil)
        #expect(Phrase("search hacker news for {query}").sample == "search hacker news for x")
    }

    @Test func fillsURLEncodedPlaceholders() {
        #expect(Phrase.fill("https://x.test/?q={query}&u={url}", ["query": "rust & go", "url": "https://a.b/?c=d"])
            == "https://x.test/?q=rust%20%26%20go&u=https://a.b/%3Fc%3Dd")
        #expect(Phrase.placeholders(in: "{a}/b/{c_d}") == ["a", "c_d"])
    }
}

struct VoiceActionTests {
    @Test func decodesAndReencodesSteps() throws {
        let original = try action(#"""
            {"name":"Mix","say":["go"],"when":{"app":"com.apple.Safari"},
             "steps":[{"open_app":"Notes"},{"open_url":"https://x.test"},{"keystroke":"cmd+d"},{"menu":["File","Save"]},{"shortcut":"S"}]}
            """#)
        #expect(original.steps == [.openApp("Notes"), .openURL("https://x.test"), .keystroke("cmd+d"), .menu(["File", "Save"]), .shortcut("S")])
        #expect(try JSONDecoder().decode(VoiceAction.self, from: ActionLibrary.encoder.encode(original)) == original)
    }

    @Test func rejectsAStepWithTwoKinds() {
        #expect(throws: DecodingError.self) { try action(#"{"name":"x","say":["x"],"steps":[{"open_app":"A","keystroke":"a"}]}"#) }
    }

    @Test func reportsProblems() throws {
        #expect(try action(#"{"name":"x","say":["x"],"steps":[{"keystroke":"hyper+q"}]}"#).problems() == [#"Keystroke "hyper+q" isn't recognized."#])
        #expect(try action(#"{"name":"x","say":["x"],"steps":[{"open_url":"https://a/{query}"}]}"#).problems().count == 1)
        #expect(try action(#"{"name":"x","say":["x {query}"],"steps":[{"open_url":"https://a/{query}?from={url}"}]}"#).problems().isEmpty)
        #expect(try action(#"{"name":"","say":[],"steps":[]}"#).problems().count == 3)
    }

    @Test func parsesKeystrokes() {
        #expect(Keystroke("cmd+shift+D") == Keystroke("⌘+⇧+d"))
        #expect(Keystroke("cmd+shift+d")?.modifiers == [.command, .shift])
        #expect(Keystroke("enter")?.key == "return")
        #expect(Keystroke("f12")?.key == "f12")
        #expect(Keystroke("cmd+") == nil)
        #expect(Keystroke("cmd+ab") == nil)
    }

    @Test func scopesByAppAndURLGlob() throws {
        let hn = try action(#"{"name":"x","say":["x"],"when":{"app":"com.apple.Safari","url":"*://news.ycombinator.com/*"},"steps":[{"keystroke":"a"}]}"#)
        #expect(hn.specificity == 2)
        #expect(hn.applies(app: "com.apple.Safari", url: "https://news.ycombinator.com/item?id=1"))
        #expect(!hn.applies(app: "com.apple.Safari", url: "https://example.com/"))
        #expect(!hn.applies(app: "com.apple.Safari", url: nil))
        #expect(!hn.applies(app: "com.google.Chrome", url: "https://news.ycombinator.com/"))
    }
}

struct CommandMatcherTests {
    private let safariMenu = [
        MenuItem(path: ["File", "Save As…"], enabled: true),
        MenuItem(path: ["Bookmarks", "Add Bookmark…"], enabled: true),
        MenuItem(path: ["File", "Print…"], enabled: false),
    ]

    private func matcher(_ actions: [VoiceAction], menu: [MenuItem], app: String = "com.apple.Safari", url: String? = nil) -> CommandMatcher {
        CommandMatcher(actions: actions, menu: menu, apps: ["safari": URL(filePath: "/Applications/Safari.app")], bundleID: app, url: url)
    }

    @Test func menuItemsMatchByTitleWithOrWithoutAnObject() {
        let m = matcher([], menu: safariMenu)
        #expect(m.match("Add bookmark") == .menu(safariMenu[1]))
        #expect(m.match("add bookmark this") == .menu(safariMenu[1]))
        #expect(m.match("save as") == .menu(safariMenu[0]))
        #expect(m.match("bookmarks add bookmark") == .menu(safariMenu[1]))
        #expect(m.match("print") == nil, "disabled items never run")
    }

    @Test func mostSpecificActionWinsThenMenuThenGlobal() throws {
        let global = try action(#"{"name":"Global","say":["save this"],"steps":[{"keystroke":"cmd+s"}]}"#)
        let safari = try action(#"{"name":"Bookmark","say":["save this"],"when":{"app":"com.apple.Safari"},"steps":[{"keystroke":"cmd+d"}]}"#)
        let hn = try action(#"{"name":"Readwise","say":["save this"],"when":{"app":"com.apple.Safari","url":"*://news.ycombinator.com/*"},"steps":[{"open_url":"https://readwise.io/save?url={url}"}]}"#)
        let all = [global, safari, hn]

        #expect(matcher(all, menu: safariMenu, url: "https://news.ycombinator.com/").match("save this") == .action(hn, parameters: [:]))
        #expect(matcher(all, menu: safariMenu, url: "https://example.com/").match("Save this.") == .action(safari, parameters: [:]))

        let pagesSave = MenuItem(path: ["File", "Save"], enabled: true)
        #expect(matcher(all, menu: [pagesSave], app: "com.apple.iWork.Pages").match("save this") == .menu(pagesSave))
        #expect(matcher(all, menu: [], app: "com.apple.iWork.Pages").match("save this") == .action(global, parameters: [:]))
    }

    @Test func builtInsOpenAppsAndSites() {
        let m = matcher([], menu: [])
        #expect(m.match("open Safari") == .openApp(name: "safari", url: URL(filePath: "/Applications/Safari.app")))
        #expect(m.match("go to example dot com") == .openURL(URL(string: "https://example.com")!))
        #expect(m.match("go to news.ycombinator.com") == .openURL(URL(string: "https://news.ycombinator.com")!))
        #expect(m.match("open the pod bay doors") == nil)
    }

    @Test func actionParametersComeFromTheUtterance() throws {
        let search = try action(#"{"name":"HN","say":["search hacker news for {query}"],"steps":[{"open_url":"https://hn.algolia.com/?q={query}"}]}"#)
        #expect(matcher([search], menu: []).match("Search Hacker News for Swift concurrency") == .action(search, parameters: ["query": "swift concurrency"]))
    }
}

struct ActionLibraryTests {
    private func library() throws -> ActionLibrary {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earshot-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ActionLibrary(directory: dir)
    }

    @Test func proposeThenApprove() throws {
        let lib = try library()
        defer { try? FileManager.default.removeItem(at: lib.directory) }
        let a = try action(#"{"name":"Stand Up!","say":["standup"],"steps":[{"open_app":"Zoom"}]}"#)
        let first = try lib.propose(a), second = try lib.propose(a)
        #expect(first.lastPathComponent == "stand-up.json")
        #expect(second.lastPathComponent == "stand-up-2.json")
        try lib.approve(first)
        #expect(lib.load().actions.map(\.action) == [a])
        #expect(lib.load(proposals: true).actions.count == 1)
    }

    @Test func refusesInvalidProposalsAndReportsBadFiles() throws {
        let lib = try library()
        defer { try? FileManager.default.removeItem(at: lib.directory) }
        #expect(throws: ActionError.self) { try lib.propose(try action(#"{"name":"x","say":["x"],"steps":[]}"#)) }
        try Data("{not json".utf8).write(to: lib.directory.appending(path: "broken.json"))
        #expect(lib.load().invalid.map(\.file.lastPathComponent) == ["broken.json"])
    }

    @Test func detectsPhraseCollisionsAtTheSameScopeOnly() throws {
        let lib = try library()
        defer { try? FileManager.default.removeItem(at: lib.directory) }
        let existing = ActionLibrary.Entry(file: lib.directory.appending(path: "a.json"),
                                           action: try action(#"{"name":"Search","say":["search for {query}"],"steps":[{"open_url":"https://x/{query}"}]}"#))
        let same = try action(#"{"name":"Other","say":["search for {q}"],"steps":[{"open_url":"https://y/{q}"}]}"#)
        let scoped = try action(#"{"name":"Scoped","say":["search for {q}"],"when":{"app":"com.apple.Safari"},"steps":[{"open_url":"https://y/{q}"}]}"#)
        #expect(lib.collisions(same, with: [existing]) == [#""search for {q}" (Search)"#])
        #expect(lib.collisions(scoped, with: [existing]).isEmpty, "a scoped action overrides, it doesn't collide")
    }
}

struct MakeActionTests {
    @Test func recognizesRequests() {
        #expect(VoiceCommands.actionRequest("Make an action: when I say standup, open Zoom.") == "when I say standup, open Zoom")
        #expect(VoiceCommands.actionRequest("new command open notes") == "open notes")
        #expect(VoiceCommands.actionRequest("make an actionable list") == nil)
        #expect(VoiceCommands.actionRequest("save this") == nil)
    }

    @Test func decodesClaudesReplyEvenInAFence() throws {
        let reply = "```json\n{\"name\":\"Standup\",\"say\":[\"standup\"],\"steps\":[{\"open_app\":\"Zoom\"}]}\n```"
        #expect(try VoiceCommands.decodeDraft(reply).name == "Standup")
        #expect(throws: ActionError.self) { try VoiceCommands.decodeDraft("Sorry, I can't.") }
    }
}

struct ClaudeRouterTests {
    private let iterm = URL(filePath: "/Applications/iTerm.app")

    @Test func mapsTheChosenLineToItsCommand() throws {
        let search = try action(#"{"name":"HN","say":["hn {query}"],"steps":[{"open_url":"https://x/{query}"}]}"#)
        let save = MenuItem(path: ["File", "Save"], enabled: true)
        let candidates: [ClaudeRouter.Candidate] = [.action(search), .menu(save), .app(name: "iTerm", url: iterm)]

        #expect(ClaudeRouter.match(try ClaudeRouter.decode(#"{"command": "Open app: iTerm", "parameters": []}"#), candidates: candidates)
            == .openApp(name: "iTerm", url: iterm))
        #expect(ClaudeRouter.match(.init(command: "Menu: File › Save", parameters: nil), candidates: candidates) == .menu(save))
        #expect(ClaudeRouter.match(.init(command: "Action: HN (says: hn {query})", parameters: ["swift"]), candidates: candidates)
            == .action(search, parameters: ["query": "swift"]))
        #expect(ClaudeRouter.match(.init(command: "Action: HN (says: hn {query})", parameters: []), candidates: candidates) == nil,
                "missing parameter")
        #expect(ClaudeRouter.match(try ClaudeRouter.decode(#"{"command": null}"#), candidates: candidates) == nil)
        #expect(ClaudeRouter.match(.init(command: "Open app: Terminal", parameters: []), candidates: candidates) == nil, "not on the list")
    }

    @Test func readsAFencedReplyAndRejectsProse() throws {
        #expect(try ClaudeRouter.decode("```json\n{\"command\": \"Menu: File › Save\"}\n```").command == "Menu: File › Save")
        #expect(throws: ActionError.self) { try ClaudeRouter.decode("I think you mean iTerm.") }
    }

    @Test func listsCandidatesWithTheUtterance() {
        let text = ClaudeRouter.input("Open High Term", candidates: [.app(name: "iTerm", url: iterm)], appName: "Finder")
        #expect(text == "Frontmost app: Finder\nCommands:\n- Open app: iTerm\n\nThe user said: \"Open High Term\"")
    }
}
