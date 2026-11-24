import AVFoundation
import CoreAudio
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

    @Test func browserCallSurvivesTabAndSpaceSwitchesWhileHoldingMic() {
        let safariMic = AudioProcess(objectID: 1, pid: 1563, bundleID: "com.apple.WebKit.GPU", isRunningInput: true, isRunningOutput: true)
        let safariIdle = AudioProcess(objectID: 1, pid: 1563, bundleID: "com.apple.WebKit.GPU", isRunningInput: false, isRunningOutput: true)

        // Doesn't start on a non-call tab.
        #expect(MeetingDetector.resolve(
            holders: [safariMic], ownPID: 999, activeCall: nil,
            windowTitles: { _ in ["Google Docs"] }) == nil)

        // Starts when the call tab is active.
        let started = MeetingDetector.resolve(
            holders: [safariMic], ownPID: 999, activeCall: nil,
            windowTitles: { _ in ["Meet - Seth / Basia"] })
        #expect(started?.platform.id == "safari")

        // Stays alive when the user switches to another tab or Space while Safari still holds the mic.
        let switchedTab = MeetingDetector.resolve(
            holders: [safariMic], ownPID: 999, activeCall: started,
            windowTitles: { _ in ["Google Calendar"] })
        #expect(switchedTab == started)

        let otherSpace = MeetingDetector.resolve(
            holders: [safariMic], ownPID: 999, activeCall: started,
            windowTitles: { _ in [] })
        #expect(otherSpace == started)

        // Ends once Safari releases the microphone.
        let ended = MeetingDetector.resolve(
            holders: [safariIdle], ownPID: 999, activeCall: started,
            windowTitles: { _ in ["Meet - Seth / Basia"] })
        #expect(ended == nil)
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

    @Test func dropsLiveEchoOfWhatTheCallJustSaid() {
        let heard = ["in theory you should be able to find it in the app.halifax.gov but I have to go through. I have to figure out I"]
        #expect(Meeting.isEcho("in theory you should be able to find it in the app.halifax.gov but I have to go through. I have to figure", of: heard))
        #expect(!Meeting.isEcho("Sorry, which portal was that again?", of: heard))
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

    @Test func discardsEmptyAndTooShortRecordings() {
        func recording(seconds: TimeInterval, words: Int, note: Bool = false, starred: Bool = false) -> Meeting {
            var m = Meeting(title: "Call", platform: "Zoom", startedAt: .now)
            m.endedAt = m.startedAt.addingTimeInterval(seconds)
            m.kind = note ? .note : .meeting
            m.starred = starred
            if words > 0 { m.lines = [.init(speaker: .others, start: 0, text: Array(repeating: "word", count: words).joined(separator: " "))] }
            return m
        }
        #expect(recording(seconds: 1800, words: 0).isDiscardable)
        #expect(recording(seconds: 20, words: 5).isDiscardable)
        #expect(!recording(seconds: 20, words: 40).isDiscardable)
        #expect(!recording(seconds: 300, words: 5).isDiscardable)
        #expect(!recording(seconds: 10, words: 3, note: true).isDiscardable)
        #expect(!recording(seconds: 1800, words: 0, starred: true).isDiscardable)

        // Existing empty ones are cleaned up when the store loads.
        let store = tempStore()
        let empty = recording(seconds: 600, words: 0), kept = recording(seconds: 600, words: 50)
        store.save(empty)
        store.save(kept)
        let reloaded = MeetingStore(directory: store.fileURL(for: kept.id).deletingLastPathComponent())
        #expect(reloaded.meetings.map(\.id) == [kept.id])
    }

    @Test func combinesTwoMeetingsIntoTheEarlierOne() {
        let store = tempStore()
        var first = Meeting(title: "Part 1", platform: "Zoom", startedAt: .now)
        first.endedAt = first.startedAt.addingTimeInterval(600)
        first.lines = [.init(speaker: .me, start: 10, text: "first half")]
        first.summary = "old notes"
        first.participants = ["Ana"]
        var second = Meeting(title: "Part 2", platform: "Zoom", startedAt: first.startedAt.addingTimeInterval(900))
        second.endedAt = second.startedAt.addingTimeInterval(300)
        second.lines = [.init(speaker: .others, start: 5, text: "second half")]
        second.participants = ["Ben", "Ana"]
        second.starred = true
        store.save(first)
        store.save(second)

        // Order of the ids doesn't matter: the earliest one is kept.
        let kept = store.combine([second.id, first.id])
        #expect(kept == first.id)
        #expect(store.meetings.count == 1)
        let merged = store.meetings[0]
        #expect(merged.lines.map(\.text) == ["first half", "second half"])
        #expect(merged.lines.map(\.start) == [10, 905])
        #expect(merged.endedAt == second.endedAt)
        #expect(merged.participants == ["Ana", "Ben"])
        #expect(merged.isStarred)
        #expect(merged.summary == nil)
        #expect(store.combine([first.id]) == nil)

        // Three at once fold in time order.
        var third = Meeting(title: "Part 3", platform: "Zoom", startedAt: first.startedAt.addingTimeInterval(2000))
        third.lines = [.init(speaker: .me, start: 1, text: "wrap up")]
        var zeroth = Meeting(title: "Part 0", platform: "Zoom", startedAt: first.startedAt.addingTimeInterval(-100))
        zeroth.lines = [.init(speaker: .me, start: 0, text: "hello")]
        store.save(third)
        store.save(zeroth)
        #expect(store.combine([first.id, third.id, zeroth.id]) == zeroth.id)
        #expect(store.meetings.map(\.id) == [zeroth.id])
        #expect(store.meetings[0].lines.map(\.text) == ["hello", "first half", "second half", "wrap up"])
    }

    @Test func editsParticipantsAndReassignsActionItems() {
        var m = Meeting(title: "Sync", platform: "Zoom", startedAt: .now)
        m.participants = ["Jon"]
        m.lines = [.init(speaker: .others, start: 0, text: "I'll send it", name: "Jon")]
        m.summary = "# Sync\n## Action items\n- [ ] Jon: send the deck\n- [x] Unassigned: book room\n  - [ ] Me: review"

        m.renameParticipant("Jon", to: "John Smith")
        #expect(m.participants == ["John Smith"])
        #expect(m.lines[0].name == "John Smith")
        #expect(m.actionItems.map(\.owner) == ["John Smith", "Unassigned", "Me"])

        m.addParticipant("  Ana ")
        m.addParticipant("Ana")
        m.addParticipant("Me")
        #expect(m.participants == ["John Smith", "Ana"])
        #expect(m.assignees == ["Me", "John Smith", "Ana", "Unassigned"])

        // Reassigning keeps the checkbox state, the indent and the task text.
        let booked = m.actionItems[1], review = m.actionItems[2]
        m.setOwner(atLine: booked.line, to: "Ana")
        m.setOwner(atLine: review.line, to: "John Smith")
        #expect(m.summary == "# Sync\n## Action items\n- [ ] John Smith: send the deck\n- [x] Ana: book room\n  - [ ] John Smith: review")

        // A task written without an owner gets one.
        m.summary = "- [ ] call the venue"
        m.setOwner(atLine: 0, to: "Ana")
        #expect(m.summary == "- [ ] Ana: call the venue")

        m.removeParticipant("Ana")
        m.removeParticipant("John Smith")
        #expect(m.participants == nil)
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

struct AudioInputSelectionTests {
    private let builtIn = AudioInputDevice(
        id: 73, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
        transport: kAudioDeviceTransportTypeBuiltIn, isRunningSomewhere: false, isDefault: true)
    private let studioDisplay = AudioInputDevice(
        id: 87, uid: "StudioDisplay", name: "Studio Display Microphone",
        transport: kAudioDeviceTransportTypeUSB, isRunningSomewhere: false, isDefault: false)
    private let iPhone = AudioInputDevice(
        id: 85, uid: "iPhoneMic", name: "iPhone Microphone",
        transport: kAudioDeviceTransportTypeContinuityCaptureWired, isRunningSomewhere: false, isDefault: false)

    private func running(_ device: AudioInputDevice) -> AudioInputDevice {
        AudioInputDevice(
            id: device.id, uid: device.uid, name: device.name,
            transport: device.transport, isRunningSomewhere: true, isDefault: device.isDefault)
    }

    @Test func followsActiveCallMicOverSystemDefault() {
        let picked = AudioInputs.preferred(
            from: [iPhone, running(studioDisplay), builtIn],
            clamshellClosed: false)
        #expect(picked?.id == studioDisplay.id)
    }

    @Test func skipsHardwareMutedBuiltInWhenClamshellClosed() {
        // Closed lid, Zoom on Studio Display, default still Built-In.
        let activeCall = AudioInputs.preferred(
            from: [iPhone, running(studioDisplay), running(builtIn)],
            clamshellClosed: true)
        #expect(activeCall?.id == studioDisplay.id)

        // Closed lid, no call active: pick external USB mic, never wake idle iPhone Continuity mic.
        let idle = AudioInputs.preferred(
            from: [iPhone, studioDisplay, builtIn],
            clamshellClosed: true)
        #expect(idle?.id == studioDisplay.id)

        // Closed lid with only Built-In + idle Continuity iPhone: don't chime the phone.
        let onlyContinuity = AudioInputs.preferred(
            from: [iPhone, builtIn],
            clamshellClosed: true)
        #expect(onlyContinuity?.id == builtIn.id)
    }

    @Test func usesDefaultWhenOpenAndNothingElseRunning() {
        let picked = AudioInputs.preferred(
            from: [iPhone, studioDisplay, builtIn],
            clamshellClosed: false)
        #expect(picked?.id == builtIn.id)
    }

    @Test func switchesMidRecordingWhenCallStartsAnotherMicWithoutOscillating() {
        // Recording started on Built-In (now running because of Earshot), then Zoom opens Studio Display.
        let switched = AudioInputs.preferred(
            from: [iPhone, running(studioDisplay), running(builtIn)],
            clamshellClosed: false,
            currentDeviceID: builtIn.id,
            knownRunning: [builtIn.id])
        #expect(switched?.id == studioDisplay.id)

        // Once both are known running (e.g. another app also holds Built-In), stay put — no ping-pong.
        let stable = AudioInputs.preferred(
            from: [iPhone, running(studioDisplay), running(builtIn)],
            clamshellClosed: false,
            currentDeviceID: studioDisplay.id,
            knownRunning: [builtIn.id, studioDisplay.id])
        #expect(stable?.id == studioDisplay.id)
    }

    @Test func switchesAwayFromSilentOrClosedLidDevice() {
        // Lid closed mid-call while on Built-In: immediately leaves Built-In for Studio Display.
        let lidClosed = AudioInputs.preferred(
            from: [iPhone, studioDisplay, running(builtIn)],
            clamshellClosed: true,
            currentDeviceID: builtIn.id,
            knownRunning: [builtIn.id])
        #expect(lidClosed?.id == studioDisplay.id)

        // Current mic streaming pure digital silence while another mic is already active (even if known).
        let silentSwitch = AudioInputs.preferred(
            from: [iPhone, running(studioDisplay), running(builtIn)],
            clamshellClosed: false,
            currentDeviceID: builtIn.id,
            currentIsSilent: true,
            knownRunning: [builtIn.id, studioDisplay.id])
        #expect(silentSwitch?.id == studioDisplay.id)
    }

    @Test func ignoresAggregateTapDevices() {
        let tapAggregate = AudioInputDevice(
            id: 148, uid: "tap-uuid", name: SystemAudioTap.deviceName,
            transport: kAudioDeviceTransportTypeAggregate, isRunningSomewhere: true, isDefault: false)

        // Never switch mid-recording to Earshot's own call-capture aggregate device.
        let midCall = AudioInputs.preferred(
            from: [iPhone, running(studioDisplay), builtIn, tapAggregate],
            clamshellClosed: true,
            currentDeviceID: studioDisplay.id,
            knownRunning: [studioDisplay.id])
        #expect(midCall?.id == studioDisplay.id)

        // Never pick a running aggregate tap at start or as a clamshell fallback.
        let atStart = AudioInputs.preferred(
            from: [iPhone, builtIn, tapAggregate],
            clamshellClosed: true)
        #expect(atStart?.id == builtIn.id)
    }

    @Test func measureDistinguishesDigitalSilenceFromSignal() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let silent = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        silent.frameLength = 128
        for i in 0..<128 { silent.floatChannelData![0][i] = 0 }
        #expect(AudioCapture.measure(silent) == (0, false))

        let quiet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        quiet.frameLength = 128
        for i in 0..<128 { quiet.floatChannelData![0][i] = 0.0001 }
        let measured = AudioCapture.measure(quiet)
        #expect(measured.hasSignal)
        #expect(measured.level > 0)
    }

    @Test func systemAudioTapUsesAggregateNominalSampleRate() throws {
        // AirPods Pro in Bluetooth HFP run at 24 kHz while kAudioTapPropertyFormat still reports 48 kHz.
        let tapFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        var effectiveASBD = SystemAudioTap.effectiveStreamDescription(
            tapDescription: tapFormat.streamDescription.pointee,
            nominalSampleRate: 24_000)
        #expect(effectiveASBD.mSampleRate == 24_000)
        #expect(effectiveASBD.mChannelsPerFrame == 2)

        // Zero/unavailable nominal rate preserves the tap's original sample rate.
        let fallback = SystemAudioTap.effectiveStreamDescription(
            tapDescription: tapFormat.streamDescription.pointee,
            nominalSampleRate: 0)
        #expect(fallback.mSampleRate == 48_000)

        // 20 ms at 24 kHz (480 frames) must convert to ~20 ms at 16 kHz (320 frames), not 10 ms (160 frames).
        let inputFormat = try #require(AVAudioFormat(streamDescription: &effectiveASBD))
        let targetFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: targetFormat))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480))
        input.frameLength = 480
        let samples = input.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<480 {
            let value = sinf(2 * .pi * 440 * Float(i) / 24_000) * 0.5
            samples[i * 2] = value
            samples[i * 2 + 1] = value
        }
        let converted = try #require(AudioCapture.convert(input, with: converter, to: targetFormat))
        #expect(converted.frameLength >= 300 && converted.frameLength <= 325)
        let outSamples = try #require(converted.int16ChannelData?[0])
        let peak = (0..<Int(converted.frameLength)).map { abs(Int(outSamples[$0])) }.max() ?? 0
        #expect(peak > 1000)
    }
}

struct PillDockTests {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 900)

    @Test func picksNearestEdgeUsingNormalizedCoordinates() {
        #expect(PillDock.nearest(to: CGPoint(x: 800, y: 850), in: screen) == .top)
        #expect(PillDock.nearest(to: CGPoint(x: 800, y: 50), in: screen) == .bottom)
        #expect(PillDock.nearest(to: CGPoint(x: 100, y: 450), in: screen) == .left)
        #expect(PillDock.nearest(to: CGPoint(x: 1500, y: 450), in: screen) == .right)
        // Wide display: 25% from the left at vertical midpoint still docks left (0.25 < 0.5).
        #expect(PillDock.nearest(to: CGPoint(x: 400, y: 450), in: screen) == .left)
        #expect(PillDock.nearest(to: CGPoint(x: 1200, y: 450), in: screen) == .right)
    }

    @Test func dockedFramesStayInsideVisibleScreen() {
        for edge in PillDock.allCases {
            let rect = edge.frame(in: screen)
            #expect(screen.contains(rect))
        }
        #expect(PillDock.top.frame(in: screen).midY > PillDock.bottom.frame(in: screen).midY)
        #expect(PillDock.left.frame(in: screen).midX < PillDock.right.frame(in: screen).midX)
        #expect(PillDock.top.isHorizontal && PillDock.bottom.isHorizontal)
        #expect(!PillDock.left.isHorizontal && !PillDock.right.isHorizontal)
    }
}
