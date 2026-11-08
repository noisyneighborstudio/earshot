import AVFoundation
import Foundation
import Testing
@testable import Earshot

struct FocusContextTests {
    @Test func textBeforeSelection() {
        #expect(FocusContext.before("Hello brave world", selection: NSRange(location: 6, length: 5)) == "Hello ")
    }

    @Test func invalidSelectionAssumesEnd() {
        #expect(FocusContext.before("abc", selection: NSRange(location: 10, length: 2)) == "abc")
    }

    @Test func truncatesLongContext() {
        let value = String(repeating: "a", count: 5000)
        #expect(FocusContext.before(value, selection: NSRange(location: 2500, length: 0)).count == FocusContext.maxBefore)
    }

    @Test func usesUTF16Offsets() {
        // "👋" is two UTF-16 units; AX ranges are UTF-16.
        #expect(FocusContext.before("👋 hi", selection: NSRange(location: 3, length: 2)) == "👋 ")
    }
}

struct SpacingTests {
    @Test func addsSpaceAfterWord() { #expect(Spacing.join(before: "Hello", insert: "world") == " world") }
    @Test func noSpaceAfterWhitespace() { #expect(Spacing.join(before: "Hello ", insert: "world") == "world") }
    @Test func noSpaceBeforePunctuation() { #expect(Spacing.join(before: "Hello", insert: ", world") == ", world") }
    @Test func noSpaceAfterOpener() { #expect(Spacing.join(before: "(", insert: "aside") == "aside") }
    @Test func emptyField() { #expect(Spacing.join(before: "", insert: "Hi") == "Hi") }
}

struct HotkeyTests {
    @Test func deviceFlagsDistinguishSides() {
        #expect(Hotkey.rightOption.deviceFlag != Hotkey.rightCommand.deviceFlag)
        #expect(Hotkey.fn.keyCode == 63)
    }
}

/// Real on-device recognition of synthesized speech. Downloads the model on first run.
/// Run with: EARSHOT_INTEGRATION=1 xcodebuild test ...
@MainActor
struct OnDeviceTranscriptionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EARSHOT_INTEGRATION"] == "1"), .timeLimit(.minutes(10)))
    func transcribesSynthesizedSpeech() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "earshot-test.aiff")
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "The quick brown fox jumps over the lazy dog."]
        try say.run()
        say.waitUntilExit()

        let engine = SpeechEngine()
        engine.prepare(localeIdentifier: "en_US")
        while engine.status == .preparing || { if case .downloading = engine.status { true } else { false } }() {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(engine.status == .ready)

        let made = engine.makeSession(contextualStrings: [], onTranscript: { _ in })
        let session = try #require(made)
        let file = try AVAudioFile(forReading: url)
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: session.format))
        while file.framePosition < file.length {
            let chunk = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: chunk)
            let out = try #require(AVAudioPCMBuffer(
                pcmFormat: session.format,
                frameCapacity: AVAudioFrameCount(Double(chunk.frameLength) * session.format.sampleRate / file.processingFormat.sampleRate) + 1))
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return chunk
            }
            session.append(out)
        }
        let text = try await session.finish().text.lowercased()
        #expect(text.contains("quick brown fox"))
        #expect(text.contains("lazy dog"))
    }
}

struct MeetingPlatformTests {
    @Test func nativeAppsAndHelpers() {
        #expect(MeetingPlatform.forBundleID("us.zoom.xos")?.id == "zoom")
        #expect(MeetingPlatform.forBundleID("com.tinyspeck.slackmacgap.helper")?.name == "Slack")
        #expect(MeetingPlatform.forBundleID("com.google.Chrome.helper")?.isBrowser == true)
        #expect(MeetingPlatform.forBundleID("com.apple.Music") == nil)
    }

    @Test func browserCallTitles() {
        #expect(MeetingPlatform.looksLikeCall(windowTitle: "Meet – abc-defg-hij"))
        #expect(!MeetingPlatform.looksLikeCall(windowTitle: "Inbox - Gmail"))
    }
}

struct MeetingModelTests {
    @Test func mergesSpeakersByTime() {
        let lines = Meeting.lines(
            me: [.init(start: 5, end: 6, text: "second"), .init(start: 20, end: 21, text: "fourth")],
            others: [.init(start: 1, end: 2, text: "first"), .init(start: 10, end: 11, text: "third")])
        #expect(lines.map(\.text) == ["first", "second", "third", "fourth"])
        #expect(lines.map(\.speaker) == [.others, .me, .others, .me])
    }

    @Test func formatsTimestamps() {
        #expect(Meeting.timestamp(65) == "01:05")
        #expect(Meeting.timestamp(3725) == "1:02:05")
    }

    @Test func transcriptAndSummaryInput() {
        var meeting = Meeting(title: "Standup", platform: "Zoom", startedAt: .now)
        meeting.lines = [.init(speaker: .me, start: 3, text: "Ship it Friday.")]
        #expect(meeting.transcriptText == "[00:03] Me: Ship it Friday.")
        #expect(MeetingSummarizer.input(for: meeting).contains("Meeting: Standup (Zoom)"))
        #expect(meeting.markdown.hasPrefix("# Standup"))
    }
}

/// Real call-path checks. Run with EARSHOT_INTEGRATION=1; needs System Audio Recording permission.
@MainActor
struct MeetingIntegrationTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["EARSHOT_INTEGRATION"] == "1" }

    @Test(.enabled(if: enabled)) func listsAudioProcesses() {
        let processes = AudioProcesses.all()
        #expect(!processes.isEmpty)
        #expect(processes.contains { !$0.bundleID.isEmpty })
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(2)))
    func transcribesSystemAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "earshot-call.aiff")
        try run("/usr/bin/say", ["-o", url.path, "Let's ship the release on Friday afternoon."])

        let engine = SpeechEngine()
        engine.prepare(localeIdentifier: "en_US")
        while engine.status != .ready {
            if case .failed = engine.status { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let made = engine.makeSession(contextualStrings: [], onTranscript: { _ in })
        let session = try #require(made)
        let tap = SystemAudioTap()
        try tap.start(processes: [], format: session.format) { session.append($0) }
        try await Task.sleep(for: .milliseconds(300))
        try run("/usr/bin/afplay", [url.path])
        try await Task.sleep(for: .milliseconds(500))
        tap.stop()
        let text = try await session.finish().text.lowercased()
        print("system audio transcript: \(text)")
        #expect(text.contains("release"))
        #expect(text.contains("friday"))
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(5)))
    func summarizesWithClaudeCLI() async throws {
        let cli = try #require(ClaudeCLI.locate())
        var meeting = Meeting(title: "Release sync", platform: "Zoom", startedAt: .now)
        meeting.lines = [
            .init(speaker: .others, start: 1, text: "Can we ship the release Friday?"),
            .init(speaker: .me, start: 4, text: "Yes. I'll update the changelog by Thursday."),
            .init(speaker: .others, start: 8, text: "Great, I'll tell support."),
        ]
        let notes = try await MeetingSummarizer(cli: cli).summarize(meeting)
        print("notes:\n\(notes)")
        #expect(notes.hasPrefix("# "))
        #expect(notes.contains("## Action items"))
        #expect(notes.lowercased().contains("changelog"))
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }
}

struct SpeakerDetectionTests {
    let zoom = SpeakerMarkers(templates: ["Talking: %@", "Sprechen: %@", "発言中: %@"])

    @Test func zoomLocalizedTemplates() {
        #expect(zoom.name(in: "Talking: Priya Shah") == "Priya Shah")
        #expect(zoom.name(in: "Sprechen: Jonas") == "Jonas")
        #expect(zoom.name(in: "発言中: 田中") == "田中")
        #expect(zoom.name(in: "Talking: ") == nil)
        #expect(zoom.name(in: "Mute") == nil)
    }

    @Test func genericLabelsAndCleanup() {
        let generic = SpeakerMarkers(templates: [])
        #expect(generic.name(in: "Alex Kim is speaking") == "Alex Kim")
        #expect(generic.name(in: "Sam (Host), speaking") == "Sam")
        #expect(SpeakerMarkers.clean("+3 more") == nil)
        #expect(SpeakerMarkers.clean("Seth Webster (You)") == "Seth Webster")
    }

    @Test func attributesSegmentsToDominantSpeaker() {
        let timeline = [
            SpeakerSample(time: 1.0, names: ["Priya"]), SpeakerSample(time: 1.5, names: ["Priya"]),
            SpeakerSample(time: 2.0, names: ["Jonas"]), SpeakerSample(time: 9.0, names: ["Jonas"]),
        ]
        #expect(SpeakerAttribution.speaker(for: .init(start: 0.8, end: 2.2, text: "a"), in: timeline) == "Priya")
        #expect(SpeakerAttribution.speaker(for: .init(start: 8.5, end: 9.5, text: "b"), in: timeline) == "Jonas")
        #expect(SpeakerAttribution.speaker(for: .init(start: 20, end: 21, text: "c"), in: timeline) == nil)
    }

    @Test func namesFlowIntoTranscript() {
        var meeting = Meeting(title: "Sync", platform: "Zoom", startedAt: .now)
        meeting.lines = Meeting.lines(
            me: [.init(start: 0, end: 1, text: "Hi all.")],
            others: [.init(start: 2, end: 3, text: "Morning.")],
            speakers: [SpeakerSample(time: 2.5, names: ["Priya"])])
        #expect(meeting.transcriptText == "[00:00] Me: Hi all.\n[00:02] Priya: Morning.")
    }

    @Test func readsInstalledZoomTemplate() {
        let markers = SpeakerMarkers.forPlatform(MeetingPlatform.forBundleID("us.zoom.xos")!)
        #expect(markers.templates.contains("Talking: %@"))
    }
}

struct NotesInteractionTests {
    @Test func togglesActionItems() {
        var meeting = Meeting(title: "Sync", platform: "", startedAt: .now)
        meeting.summary = "# Sync\n## Action items\n- [ ] Me: Update the changelog\n- [x] Priya: Tell support"
        #expect(meeting.openTaskCount == 1)
        meeting.toggleTask(atLine: 2)
        #expect(meeting.summary?.contains("- [x] Me: Update the changelog") == true)
        meeting.toggleTask(atLine: 3)
        #expect(meeting.summary?.contains("- [ ] Priya: Tell support") == true)
        #expect(meeting.openTaskCount == 1)
    }

    @Test func durationAndUpdateDisplay() {
        var meeting = Meeting(title: "Sync", platform: "", startedAt: Date(timeIntervalSince1970: 0))
        meeting.endedAt = Date(timeIntervalSince1970: 1440)
        #expect(meeting.duration == 1440)
        #expect(TranscriptUpdate(finals: "Hello", volatile: "world").display == "Hello world")
        #expect(TranscriptUpdate(finals: "Hello", volatile: "").display == "Hello")
    }
}

struct MeetingTitleTests {
    @Test func cleansModelOutput() {
        #expect(MeetingTitler.clean("\"Friday release go-ahead.\"\n") == "Friday release go-ahead")
        #expect(MeetingTitler.clean("# Q3 launch timeline") == "Q3 launch timeline")
        #expect(MeetingTitler.clean("   \n") == nil)
        #expect(MeetingTitler.clean(String(repeating: "word ", count: 30))!.hasSuffix("…"))
    }

    @Test func titleFromNotesHeading() {
        #expect(MeetingTitler.fromNotes("# Onboarding design review\n## Summary\nText") == "Onboarding design review")
        #expect(MeetingTitler.fromNotes("## Summary\nNo title") == nil)
    }

    @Test func placeholderAndWordCount() {
        #expect(MeetingTitler.placeholder(platform: "Zoom", startedAt: .now) == "Zoom call")
        #expect(MeetingTitler.placeholder(platform: "", startedAt: .now) == "Untitled meeting")
        #expect(MeetingRow.minutes(9) == "9 sec")
        #expect(MeetingRow.minutes(90) == "2 min")
        var meeting = Meeting(title: "", platform: "", startedAt: .now)
        meeting.lines = [.init(speaker: .me, start: 0, text: "one two three"), .init(speaker: .others, start: 1, text: "four")]
        #expect(meeting.wordCount == 4)
    }

    @Test(.enabled(if: MeetingIntegrationTests.enabled), .timeLimit(.minutes(1)))
    func generatesLiveTitle() async throws {
        let cli = try #require(ClaudeCLI.locate())
        var meeting = Meeting(title: "", platform: "Zoom", startedAt: .now)
        meeting.lines = [
            .init(speaker: .others, start: 1, text: "Let's go through the onboarding flow redesign. The new welcome screen tested well."),
            .init(speaker: .me, start: 6, text: "Agreed. The permissions step is still confusing though, people drop off there."),
            .init(speaker: .others, start: 12, text: "We could split permissions into two screens and explain each one."),
        ]
        let title = try #require(try await MeetingTitler(cli: cli).title(for: meeting))
        print("live title: \(title)")
        #expect(!title.isEmpty && title.split(separator: " ").count <= 8)
        #expect(title.lowercased().contains("onboarding") || title.lowercased().contains("permission"))
    }
}

/// The whole meeting path through MeetingRecorder: live lines, autosave, notes, title.
@MainActor
struct MeetingRecorderIntegrationTests {
    @Test(.enabled(if: MeetingIntegrationTests.enabled), .timeLimit(.minutes(5)))
    func recordsTranscribesSavesAndSummarizes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "earshot-meetings-\(UUID().uuidString)")
        let store = MeetingStore(directory: directory)
        let speech = SpeechEngine()
        speech.prepare(localeIdentifier: "en_US")
        while speech.status != .ready {
            if case .failed = speech.status { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let recorder = MeetingRecorder(speech: speech, store: store, settings: AppSettings())

        let audio = FileManager.default.temporaryDirectory.appending(path: "earshot-meeting.aiff")
        try run("/usr/bin/say", ["-o", audio.path,
            "Thanks everyone. The onboarding redesign tested well. Priya will split the permissions step into two screens by next Tuesday."])

        recorder.start(call: nil, processes: [], pids: [], includeComputerAudio: true)
        #expect(recorder.lastError == nil)
        #expect(recorder.state == .recording)
        try await Task.sleep(for: .milliseconds(400))
        try run("/usr/bin/afplay", [audio.path])
        try run("/usr/bin/afplay", [audio.path])

        // Live lines must arrive before Stop…
        let deadline = ContinuousClock.now + .seconds(15)
        while (recorder.current?.lines.isEmpty ?? true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        let live = try #require(recorder.current)
        print("live lines: \(live.lines.map(\.text))")
        #expect(!live.lines.isEmpty)

        // …and reach disk without waiting for Stop.
        try await Task.sleep(for: .seconds(6))
        let saved = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: directory.appending(path: "\(live.id.uuidString).json")))
        print("saved lines before stop: \(saved.lines.count)")
        #expect(!saved.lines.isEmpty)

        recorder.stop()
        while recorder.state != .idle { try await Task.sleep(for: .milliseconds(250)) }
        let final = try #require(store.meetings.first { $0.id == live.id })
        print("final title: \(final.title)\nerror: \(final.summaryError ?? "none")\ntranscript:\n\(final.transcriptText)")
        #expect(final.endedAt != nil)
        let transcript = final.transcriptText.lowercased()
        #expect(transcript.contains("boarding") && transcript.contains("tuesday"))
        #expect(!final.lines.contains { $0.text == "." })
        // Echo removal: what the speakers played shouldn't come back as "Me".
        #expect(!final.lines.contains { $0.speaker == .me && $0.text.lowercased().contains("tuesday") })
        #expect(final.summary != nil)
        #expect(final.title != "Untitled meeting")
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }
}

struct EchoTests {
    @Test func dropsMicEchoOfCallAudio() {
        let others = [TranscriptSegment(start: 0, end: 6, text: "The onboarding redesign tested well, ship it Tuesday.")]
        let echo = TranscriptSegment(start: 0.4, end: 6.2, text: "the on boarding redesign tested well ship it Tuesday")
        let reply = TranscriptSegment(start: 7, end: 9, text: "Great, I'll update the changelog.")
        let short = TranscriptSegment(start: 1, end: 1.5, text: "Yes.")
        #expect(Meeting.isEcho(echo, of: others))
        #expect(!Meeting.isEcho(reply, of: others))
        #expect(!Meeting.isEcho(short, of: others))
        let lines = Meeting.lines(me: [echo, reply], others: others)
        #expect(lines.map(\.speaker) == [.others, .me])
    }

    @Test func keepsSameWordsFarApartInTime() {
        let others = [TranscriptSegment(start: 0, end: 4, text: "Let's ship the release Friday")]
        let later = TranscriptSegment(start: 60, end: 63, text: "So we ship the release Friday")
        #expect(!Meeting.isEcho(later, of: others))
    }
}

@MainActor
struct FoundationTests {
    private func tempStore() -> MeetingStore {
        MeetingStore(directory: FileManager.default.temporaryDirectory.appending(path: "earshot-store-\(UUID().uuidString)"))
    }

    private func meeting(_ title: String, summary: String? = nil, ended: Bool = true) -> Meeting {
        var m = Meeting(title: title, platform: "Zoom", startedAt: .now)
        m.summary = summary
        if ended { m.endedAt = m.startedAt.addingTimeInterval(600) }
        m.lines = [.init(speaker: .me, start: 0, text: "hello")]
        return m
    }

    @Test func renameStarMoveAndUndoDelete() {
        let store = tempStore()
        let m = meeting("Standup")
        store.save(m)
        store.rename(m.id, to: "  Daily standup ")
        store.toggleStar(m.id)
        store.move(m.id, toFolder: "Product")
        let saved = store.meetings.first { $0.id == m.id }
        #expect(saved?.title == "Daily standup")
        #expect(saved?.isStarred == true)
        #expect(saved?.folder == "Product")
        #expect(store.folders == ["Product"])

        let removed = store.delete(m.id)
        #expect(store.meetings.isEmpty)
        store.restore(removed!)
        #expect(store.meetings.first?.title == "Daily standup")
        // Persisted: a fresh store over the same directory sees it.
        let reloaded = MeetingStore(directory: store.fileURL(for: m.id).deletingLastPathComponent())
        #expect(reloaded.meetings.first?.folder == "Product")
        #expect(reloaded.folders == ["Product"])
    }

    @Test func foldersCreateRenameDelete() {
        let store = tempStore()
        let m = meeting("Hiring sync")
        store.save(m)
        store.createFolder("Hiring")
        store.createFolder("Empty")
        store.move(m.id, toFolder: "Hiring")
        #expect(store.folders == ["Empty", "Hiring"])
        store.renameFolder("Hiring", to: "Recruiting")
        #expect(store.meetings.first?.folder == "Recruiting")
        store.deleteFolder("Recruiting")
        #expect(store.meetings.first?.folder == nil)
        #expect(store.folders == ["Empty"])
    }

    @Test func actionItemsParseAndToggle() {
        let store = tempStore()
        let m = meeting("Sync", summary: "# Sync\n## Action items\n- [ ] Me: Update changelog\n- [x] Priya Shah: Tell support\n- [ ] Ship it")
        store.save(m)
        let items = store.meetings[0].actionItems
        #expect(items.map(\.owner) == ["Me", "Priya Shah", nil])
        #expect(items.map(\.done) == [false, true, false])
        #expect(items[0].isMine && items[0].line == 2)
        store.toggleTask(items[0])
        #expect(store.meetings[0].actionItems[0].done)
    }

    @Test func usageStats() {
        let today = Date.now
        let history = [
            HistoryEntry(date: today, app: "Slack", raw: "a b c", text: "One two three four"),
            HistoryEntry(date: today, app: "Mail", raw: "x y", error: "failed"),
            HistoryEntry(date: today.addingTimeInterval(-86_400 * 2), app: "Notes", raw: "old", text: "old words here"),
        ]
        var withNotes = meeting("A", summary: "# A\n- [ ] Me: one\n- [ ] Jonas: two\n- [x] Me: done")
        withNotes.startedAt = today
        var needsNotes = meeting("B")
        needsNotes.summaryError = "failed"
        let stats = UsageStats.compute(history: history, meetings: [withNotes, needsNotes], now: today)
        #expect(stats.wordsDictatedToday == 4)
        #expect(stats.meetingsToday == 2)
        #expect(stats.meetingMinutesToday == 20)
        #expect(stats.meetingsNeedingNotes == 1)
        #expect(stats.openActionItems == 2)
        #expect(stats.myOpenActionItems == 1)
    }

    @Test func suggestionsThresholdAcceptDismiss() {
        let url = FileManager.default.temporaryDirectory.appending(path: "earshot-suggestions-\(UUID().uuidString).json")
        let suggestions = DictionarySuggestions(url: url)
        suggestions.record(["Lyft"], dictionary: [])
        #expect(suggestions.ready.isEmpty)
        suggestions.record(["lyft", "Grafana"], dictionary: ["grafana"])
        #expect(suggestions.ready.map(\.word) == ["Lyft"])
        suggestions.dismiss(suggestions.ready[0])
        suggestions.record(["Lyft", "Lyft"], dictionary: [])
        #expect(suggestions.ready.isEmpty)
        #expect(DictionarySuggestions(url: url).all.isEmpty)
    }
}

struct VoiceNoteTests {
    @Test func notesUseTheirOwnPrompt() {
        var note = Meeting(title: "Voice note", platform: "", startedAt: .now)
        note.kind = .note
        #expect(note.isNote)
        #expect(MeetingSummarizer.noteSystem.contains("voice note"))
        #expect(!Meeting(title: "Sync", platform: "Zoom", startedAt: .now).isNote)
    }

    @Test func oldMeetingsDecodeWithoutKind() throws {
        let json = #"{"id":"F7982D60-2011-4EB4-B8F4-79B5077B4385","title":"Old","platform":"","startedAt":0,"lines":[]}"#
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        #expect(meeting.kind == nil && !meeting.isNote)
    }
}
