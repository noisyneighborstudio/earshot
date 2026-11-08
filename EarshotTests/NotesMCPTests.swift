import Foundation
import Testing
@testable import Earshot

/// A throwaway Earshot data directory (Meetings/ + history.json).
private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "earshot-notes-\(UUID().uuidString)")
    var meetings: URL { root.appending(path: "Meetings") }

    init() throws { try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true) }

    func write(_ meeting: Meeting) throws {
        try JSONEncoder().encode(meeting).write(to: meetings.appending(path: "\(meeting.id.uuidString).json"), options: .atomic)
    }

    func raw(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: meetings.appending(path: name))
    }

    var library: NotesLibrary { NotesLibrary(directory: root) }
}

private func day(_ text: String) -> Date { try! NotesLibrary.date(text, name: "test", endOfDay: false) }

private func meeting(
    _ title: String, on date: String, notes: String? = nil, lines: [String] = [], people: [String]? = nil,
    kind: Meeting.Kind = .meeting, ended: Bool = true
) -> Meeting {
    var meeting = Meeting(title: title, platform: "Zoom", startedAt: day(date))
    meeting.endedAt = ended ? meeting.startedAt.addingTimeInterval(1800) : nil
    meeting.summary = notes
    meeting.kind = kind
    meeting.participants = people
    meeting.lines = lines.enumerated().map { index, text in
        Meeting.Line(speaker: index.isMultiple(of: 2) ? .me : .others, start: Double(index * 10), text: text,
                     name: index.isMultiple(of: 2) ? nil : people?.first)
    }
    return meeting
}

private func args(_ json: String) throws -> ToolArguments {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(ToolArguments.self, from: Data(json.utf8))
}

struct NotesLibraryLoadingTests {
    @MainActor @Test func readsWhatTheAppWrites() async throws {
        let fixture = try Fixture()
        let store = MeetingStore(directory: fixture.meetings)
        var saved = meeting("Roadmap", on: "2026-03-02", notes: "## Action items\n- [ ] Me: draft plan", people: ["Ana"])
        saved.folder = "Planning"
        saved.starred = true
        store.save(saved)
        store.createFolder("Planning")

        let page = try await fixture.library.list(args("{}"))
        #expect(page.items.map(\.id) == [saved.id])
        #expect(page.items[0].folder == "Planning" && page.items[0].starred == true)
        #expect(page.items[0].openActionItems == 1)
        #expect(page.unreadableFiles == nil)
    }

    @Test func decodesOlderFilesWithoutNewerFields() async throws {
        let fixture = try Fixture()
        let id = UUID()
        try fixture.raw("\(id.uuidString).json", """
            {"id":"\(id.uuidString)","title":"Old","platform":"","startedAt":700000000,"endedAt":700000600,"lines":[]}
            """)
        let item = try #require(try await fixture.library.list(args("{}")).items.first)
        #expect(item.kind == .meeting)
        #expect(item.status == .notesPending)
        #expect(item.starred == nil && item.platform == nil)
    }

    @Test func skipsAndReportsUnreadableFiles() async throws {
        let fixture = try Fixture()
        try fixture.write(meeting("Good", on: "2026-03-02"))
        try fixture.raw("\(UUID().uuidString).json", #"{"id":"trunc"#)
        try fixture.raw("\(UUID().uuidString).json", #"{"title":5}"#)
        try fixture.raw("folders.json", #"["A"]"#)
        try fixture.raw("notes.json", "not a meeting")
        try fixture.raw("x.tmp", "partial")

        let page = try await fixture.library.list(args("{}"))
        #expect(page.items.map(\.title) == ["Good"])
        let unreadable = try #require(page.unreadableFiles)
        #expect(unreadable.count == 2)
        #expect(unreadable.contains { $0.hasSuffix("not valid JSON (truncated or corrupt)") })
        #expect(unreadable.contains { $0.contains("missing") || $0.contains("wrong type") })
    }

    @Test func rereadsFilesWhenTheyChange() async throws {
        let fixture = try Fixture()
        let library = fixture.library
        var live = meeting("Live call", on: "2026-03-02", lines: ["hello"], ended: false)
        try fixture.write(live)
        #expect(try await library.list(args("{}")).items.first?.status == .recording)

        live.lines.append(.init(speaker: .others, start: 20, text: "the budget is approved"))
        live.endedAt = live.startedAt.addingTimeInterval(60)
        live.summary = "## Summary\nBudget approved."
        try fixture.write(live)
        let updated = try #require(try await library.list(args("{}")).items.first)
        #expect(updated.status == .ready && updated.transcriptLines == 2)
        #expect(try await library.search(args(#"{"query":"budget"}"#)).total == 1)

        try FileManager.default.removeItem(at: fixture.meetings.appending(path: "\(live.id.uuidString).json"))
        #expect(try await library.list(args("{}")).items.isEmpty)
    }

    @Test func missingDataIsAClearError() async throws {
        let library = NotesLibrary(directory: URL(filePath: "/nonexistent-earshot"))
        await #expect(throws: NotesError.self) { try await library.list(args("{}")) }
        await #expect(throws: NotesError.self) { try await library.dictations(args("{}")) }
    }

    @Test func statuses() {
        var m = meeting("A", on: "2026-03-02", ended: false)
        #expect(MeetingStatus(m) == .recording)
        m.endedAt = .now
        #expect(MeetingStatus(m) == .notesPending)
        m.summaryError = "CLI failed"
        #expect(MeetingStatus(m) == .notesFailed)
        m.summaryError = nil
        m.summary = "notes"
        #expect(MeetingStatus(m) == .ready)
    }
}

struct NotesSearchTests {
    @Test func termsFoldAndTrimPlurals() {
        #expect(Terms.of("Meetings with José's TEAM") == ["meeting", "with", "jose", "team"])
        #expect(Terms.of("class") == ["class"])
        #expect(Terms.of("東京で会議").count > 1)
    }

    @Test func titleAndCoverageOutrankPassingMentions() async throws {
        let fixture = try Fixture()
        try fixture.write(meeting("Hiring sync", on: "2026-03-01", lines: ["we might talk about the pricing later"]))
        try fixture.write(meeting("Pricing review", on: "2026-03-02", notes: "## Summary\nNew pricing tiers launch Friday."))
        try fixture.write(meeting("Standup", on: "2026-03-03", notes: "Pricing pricing pricing pricing."))
        let page = try await fixture.library.search(args(#"{"query":"pricing tiers","mode":"lexical"}"#))
        #expect(page.items.first?.meeting.title == "Pricing review")
        #expect(page.items.last?.meeting.title == "Hiring sync")
        #expect(page.semantic == "off")
        #expect(page.items.allSatisfy { $0.match == "lexical" })
    }

    @Test func transcriptSnippetsPointAtTheirLine() async throws {
        let fixture = try Fixture()
        try fixture.write(meeting("Call", on: "2026-03-02", lines: ["hi", "hello", "the invoice is late", "ok"], people: ["Ana"]))
        let hit = try #require(try await fixture.library.search(args(#"{"query":"invoice"}"#)).items.first)
        let snippet = try #require(hit.snippets.first)
        #expect(snippet.field == .transcript)
        #expect(snippet.line == 2 && snippet.at == "00:20")
        #expect(snippet.text == "Me: the invoice is late")
    }

    @Test func excerptsLongText() {
        let text = String(repeating: "filler ", count: 100) + "needle" + String(repeating: " filler", count: 100)
        let excerpt = Terms.excerpt(text, around: ["needle"])
        #expect(excerpt.contains("needle") && excerpt.hasPrefix("…") && excerpt.hasSuffix("…"))
        #expect(excerpt.count < 240)
    }

    @Test func semanticAddsMatchesKeywordsMiss() async throws {
        let fixture = try Fixture()
        try fixture.write(meeting("Pricing review", on: "2026-03-02",
                                  notes: "## Summary\nWe will raise subscription prices for the premium plan next quarter."))
        let page = try await fixture.library.search(args(#"{"query":"how much do customers pay"}"#))
        #expect(page.semantic?.hasPrefix("on") == true)
        #expect(page.items.first?.match == "semantic")
    }

    @Test func emptyOrWordlessQueriesAreErrors() async throws {
        let library = try Fixture().library
        await #expect(throws: NotesError.self) { try await library.search(args("{}")) }
        await #expect(throws: NotesError.self) { try await library.search(args(#"{"query":"  ?! "}"#)) }
    }
}

struct NotesFilterTests {
    private func library() throws -> NotesLibrary {
        let fixture = try Fixture()
        var starred = meeting("Design crit", on: "2026-03-01", people: ["José Díaz"])
        starred.starred = true
        starred.folder = "Design"
        try fixture.write(starred)
        try fixture.write(meeting("Voice memo", on: "2026-03-05", kind: .note))
        try fixture.write(meeting("Sales call", on: "2026-03-10", people: ["Kim"]))
        return fixture.library
    }

    @Test func filters() async throws {
        let library = try library()
        func titles(_ json: String) async throws -> [String] { try await library.list(args(json)).items.map(\.title) }
        #expect(try await titles("{}") == ["Sales call", "Voice memo", "Design crit"])
        #expect(try await titles(#"{"kind":"note"}"#) == ["Voice memo"])
        #expect(try await titles(#"{"participant":"jose"}"#) == ["Design crit"])
        #expect(try await titles(#"{"starred":true}"#) == ["Design crit"])
        #expect(try await titles(#"{"folder":"design"}"#) == ["Design crit"])
        #expect(try await titles(#"{"platform":"zoom","after":"2026-03-05"}"#) == ["Sales call", "Voice memo"])
        #expect(try await titles(#"{"before":"2026-03-05"}"#) == ["Voice memo", "Design crit"])
    }

    @Test func badArgumentsAreErrors() async throws {
        let library = try library()
        await #expect(throws: NotesError.self) { try await library.list(args(#"{"after":"last week"}"#)) }
        #expect(throws: DecodingError.self) { try args(#"{"kind":"podcast"}"#) }
    }

    @Test func pages() async throws {
        let library = try library()
        let first = try await library.list(args(#"{"limit":2}"#))
        #expect(first.items.count == 2 && first.total == 3 && first.nextOffset == 2)
        let second = try await library.list(args(#"{"limit":2,"offset":2}"#))
        #expect(second.items.map(\.title) == ["Design crit"] && second.nextOffset == nil)
        #expect(try await library.list(args(#"{"offset":10}"#)).items.isEmpty)
    }
}

struct NotesDetailTests {
    @Test func getsMeetingByPrefixWithPagedTranscript() async throws {
        let fixture = try Fixture()
        let m = meeting("Call", on: "2026-03-02", notes: "## Summary\nShort.", lines: (0..<5).map { "line \($0)" }, people: ["Ana"])
        try fixture.write(m)
        let library = fixture.library
        let plain = try await library.meeting(args(#"{"id":"\#(m.id.uuidString.prefix(8).lowercased())"}"#))
        #expect(plain.notes == "## Summary\nShort." && plain.transcript == nil)

        let paged = try await library.meeting(args(#"{"id":"\#(m.id.uuidString)","include_transcript":true,"transcript_offset":1,"transcript_limit":2}"#))
        let transcript = try #require(paged.transcript)
        #expect(transcript.lines == ["[00:10] Ana: line 1", "[00:20] Me: line 2"])
        #expect(transcript.total == 5 && transcript.nextOffset == 3)
    }

    @Test func badIDsAreSpecificErrors() async throws {
        let fixture = try Fixture()
        let broken = UUID()
        try fixture.raw("\(broken.uuidString).json", "{")
        let library = fixture.library
        for (id, message) in [("abc", "too short"), ("FFFFFFFF", "No meeting"), (broken.uuidString, "unreadable")] {
            do {
                _ = try await library.meeting(args(#"{"id":"\#(id)"}"#))
                Issue.record("expected an error for \(id)")
            } catch {
                #expect(error.localizedDescription.contains(message))
            }
        }
    }

    @Test func actionItems() async throws {
        let fixture = try Fixture()
        try fixture.write(meeting("A", on: "2026-03-01", notes: "- [ ] Me: send deck\n- [x] Kim: book room"))
        try fixture.write(meeting("B", on: "2026-03-02", notes: "- [ ] Kim: call vendor"))
        let library = fixture.library
        #expect(try await library.actionItems(args("{}")).items.map(\.text) == ["call vendor", "send deck"])
        #expect(try await library.actionItems(args(#"{"state":"done"}"#)).items.map(\.text) == ["book room"])
        #expect(try await library.actionItems(args(#"{"state":"all","owner":"kim"}"#)).items.count == 2)
        let json = try Output.json(try await library.actionItems(args(#"{"owner":"me"}"#)))
        #expect(json.contains(#""meeting_title":"A""#) && !json.contains("line"))
    }

    @Test func dictations() async throws {
        let fixture = try Fixture()
        let entries = [
            HistoryEntry(date: day("2026-03-01"), app: "Slack", raw: "um ship friday", text: "Ship Friday."),
            HistoryEntry(date: day("2026-03-02"), app: "Mail", raw: "hello there", text: nil, error: "paste failed"),
        ]
        try JSONEncoder().encode(entries).write(to: fixture.root.appending(path: "history.json"))
        let library = fixture.library
        #expect(try await library.dictations(args("{}")).items.map(\.app) == ["Mail", "Slack"])
        #expect(try await library.dictations(args(#"{"query":"friday"}"#)).items.map(\.text) == ["Ship Friday."])
        let failed = try #require(try await library.dictations(args(#"{"app":"mail"}"#)).items.first)
        #expect(failed.text == "hello there" && failed.error == "paste failed")
    }

    @Test func briefCollectsMeetingsWithThePerson() async throws {
        let fixture = try Fixture()
        try fixture.write(meeting("1:1", on: "2026-03-01", notes: "## Summary\nTalked roadmap.\n- [ ] Me: send Ana the doc", people: ["Ana"]))
        try fixture.write(meeting("Other", on: "2026-03-02", notes: "Unrelated."))
        let brief = try await fixture.library.brief(person: "ana", topic: "roadmap")
        #expect(brief.contains("about roadmap") && brief.contains("Talked roadmap.") && brief.contains("send Ana the doc"))
        #expect(!brief.contains("Unrelated."))
    }
}

struct AgentSetupTests {
    let helper = URL(filePath: "/Applications/NN Earshot.app/Contents/MacOS/earshot-mcp")

    @Test func placement() {
        let home = URL(filePath: "/Users/me")
        #expect(AgentSetup.placement(of: URL(filePath: "/Applications/NN Earshot.app"), home: home) == .ok)
        #expect(AgentSetup.placement(of: URL(filePath: "/Users/me/Applications/NN Earshot.app"), home: home) == .ok)
        #expect(AgentSetup.placement(of: URL(filePath: "/private/var/folders/x/AppTranslocation/ABC/d/NN Earshot.app"), home: home) == .translocated)
        #expect(AgentSetup.placement(of: URL(filePath: "/Users/me/Downloads/NN Earshot.app"), home: home) == .outsideApplications)
        #expect(AgentSetup.placement(of: URL(filePath: "/Volumes/NN Earshot/NN Earshot.app"), home: home) == .outsideApplications)
        #expect(AgentSetup.helper(in: URL(filePath: "/Applications/NN Earshot.app")) == helper)
    }

    @Test func cliArguments() {
        #expect(AgentSetup.claudeAdd(helper) == ["mcp", "add", "--scope", "user", "earshot", "--", helper.path])
        #expect(AgentSetup.codexAdd(helper) == ["mcp", "add", "earshot", "--", helper.path])
        #expect(AgentSetup.command(helper) == #""/Applications/NN Earshot.app/Contents/MacOS/earshot-mcp""#)
    }

    @Test func cursorLink() throws {
        let components = try #require(URLComponents(url: AgentSetup.cursorURL(helper), resolvingAgainstBaseURL: false))
        #expect(components.scheme == "cursor" && components.host == "anysphere.cursor-deeplink" && components.path == "/mcp/install")
        #expect(components.queryItems?.first { $0.name == "name" }?.value == "earshot")
        let config = try #require(components.queryItems?.first { $0.name == "config" }?.value)
        let json = try #require(Data(base64Encoded: config))
        #expect(try JSONSerialization.jsonObject(with: json) as? [String: String] == ["command": helper.path])
    }

    @Test func vsCodeLink() throws {
        let url = AgentSetup.vsCodeURL(helper).absoluteString
        #expect(url.hasPrefix("vscode:mcp/install?"))
        let json = try #require(url.dropFirst("vscode:mcp/install?".count).removingPercentEncoding)
        #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] == ["name": "earshot", "command": helper.path])
    }

    @Test func jsonConfigAndStatus() throws {
        let config = AgentSetup.jsonConfig(helper)
        let parsed = try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: [String: [String: String]]]
        #expect(parsed?["mcpServers"]?["earshot"]?["command"] == helper.path)
        #expect(AgentSetup.status(ofConfig: config, helper: helper) == .connected)
        #expect(AgentSetup.status(ofConfig: #"{"command":"\/Applications\/NN Earshot.app\/Contents\/MacOS\/earshot-mcp"}"#, helper: helper) == .connected)
        #expect(AgentSetup.status(ofConfig: #"{"command":"/Users/me/Downloads/NN Earshot.app/Contents/MacOS/earshot-mcp"}"#, helper: helper) == .connectedElsewhere)
        #expect(AgentSetup.status(ofConfig: "{}", helper: helper) == .notConnected)
    }
}

/// Launches the embedded helper and speaks MCP JSON-RPC to it over stdio.
struct NotesMCPEndToEndTests {
    @Test(.timeLimit(.minutes(1))) func speaksMCPOverStdio() async throws {
        let fixture = try Fixture()
        let m = meeting("Pricing review", on: "2026-03-02", notes: "## Summary\nNew tiers.\n- [ ] Dana: update copy",
                        lines: ["ship it friday"], people: ["Dana"])
        try fixture.write(m)

        let process = Process()
        process.executableURL = AgentSetup.helper(in: Bundle.main.bundleURL)
        process.arguments = ["--data-dir", fixture.root.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }

        var responses = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        var nextID = 0
        func send(_ method: String, _ params: String) {
            nextID += 1
            input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":\#(nextID),"method":"\#(method)","params":\#(params)}"#.utf8 + [10]))
        }
        func result() async throws -> [String: Any] {
            let line = try #require(try await responses.next())
            let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(message["id"] as? Int == nextID)
            return try #require(message["result"] as? [String: Any], "\(line)")
        }
        func toolText(_ result: [String: Any]) throws -> String {
            let content = try #require(result["content"] as? [[String: Any]])
            return try #require(content.first?["text"] as? String)
        }

        send("initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}"#)
        let initialized = try await result()
        #expect((initialized["serverInfo"] as? [String: Any])?["name"] as? String == "earshot")
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8 + [10]))

        send("tools/list", "{}")
        let tools = try #require(try await result()["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String })
            == ["search_notes", "list_meetings", "get_meeting", "list_action_items", "search_dictations"])

        send("tools/call", #"{"name":"search_notes","arguments":{"query":"tiers","mode":"lexical"}}"#)
        let search = try await result()
        #expect(search["isError"] as? Bool == false)
        #expect(try toolText(search).contains(m.id.uuidString))

        send("tools/call", #"{"name":"get_meeting","arguments":{"id":"nope-nope"}}"#)
        let missing = try await result()
        #expect(missing["isError"] as? Bool == true)
        #expect(try toolText(missing).contains("No meeting"))

        send("resources/read", #"{"uri":"earshot://meeting/\#(m.id.uuidString)"}"#)
        let contents = try #require(try await result()["contents"] as? [[String: Any]])
        #expect((contents.first?["text"] as? String)?.contains("ship it friday") == true)

        send("prompts/get", #"{"name":"meeting_brief","arguments":{"person":"Dana"}}"#)
        let messages = try #require(try await result()["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
    }
}

/// Node (Claude Desktop, Claude Code) gives MCP servers a socketpair for stdio, whose st_dev is -1.
struct NotesMCPSocketStdioTests {
    @Test(.timeLimit(.minutes(1))) func answersInitializeOverSocketpair() throws {
        // Like Node: one socketpair per stream, our ends close-on-exec so only the child holds its ends.
        func pair() throws -> (ours: FileHandle, theirs: FileHandle) {
            var fds: [Int32] = [0, 0]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            return (FileHandle(fileDescriptor: fds[0], closeOnDealloc: true), FileHandle(fileDescriptor: fds[1], closeOnDealloc: true))
        }
        let stdin = try pair(), stdout = try pair()

        let process = Process()
        process.executableURL = AgentSetup.helper(in: Bundle.main.bundleURL)
        process.arguments = ["--data-dir", FileManager.default.temporaryDirectory.appending(path: "earshot-empty-\(UUID())").path]
        process.standardInput = stdin.theirs
        process.standardOutput = stdout.theirs
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        try stdin.theirs.close()
        try stdout.theirs.close()

        stdin.ours.write(Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"node","version":"1"}}}"#.utf8 + [10]))
        var reply = Data()
        while !reply.contains(10) {
            let chunk = stdout.ours.availableData  // returns what's arrived; empty at EOF (the child died)
            if chunk.isEmpty { break }
            reply += chunk
        }
        #expect(String(decoding: reply, as: UTF8.self).contains(#""serverInfo""#))
        #expect(process.isRunning)
    }
}

struct ClaudeDesktopExtensionTests {
    @Test func manifestHasRequiredFieldsAndLaunchesBundledLauncher() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(AgentSetup.mcpbManifest(version: "1.2.3").utf8)) as? [String: Any])
        #expect(object["manifest_version"] as? String == "0.3")
        #expect(object["name"] as? String == "earshot")
        #expect(object["version"] as? String == "1.2.3")
        #expect((object["author"] as? [String: Any])?["name"] as? String == "Noisy Neighbor")
        let server = try #require(object["server"] as? [String: Any])
        #expect(server["type"] as? String == "binary")
        #expect(server["entry_point"] as? String == "server/earshot")
        #expect((server["mcp_config"] as? [String: Any])?["command"] as? String == "${__dirname}/server/earshot")
    }

    @Test func launcherExecsHelperWithArgumentsEvenWithQuotesInPath() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "earshot's mcpb \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appending(path: "earshot-mcp")
        try Data("#!/bin/sh\necho \"ran $1\"\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let launcher = dir.appending(path: "launcher")
        try Data(AgentSetup.mcpbLauncher(helper).utf8).write(to: launcher)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [launcher.path, "hello world"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "ran hello world\n")
    }

    @Test func installedStatusFromClaudeDesktopRecords() {
        #expect(AgentSetup.mcpbStatus(installations: Data(#"{"extensions":{"local.mcpb.noisy-neighbor.earshot":{}}}"#.utf8)) == .connected)
        #expect(AgentSetup.mcpbStatus(installations: Data(#"{"extensions":{}}"#.utf8)) == .notConnected)
        #expect(AgentSetup.mcpbStatus(installations: Data(#"{"extensions":{"local.mcpb.x.earshotter":{}}}"#.utf8)) == .notConnected)
    }
}
