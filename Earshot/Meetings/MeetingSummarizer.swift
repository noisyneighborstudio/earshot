import Foundation

/// Meeting notes via the local Claude Code CLI. Prompts are model-facing, so not localized.
struct MeetingSummarizer: Sendable {
    let cli: ClaudeCLI

    static let system = """
    You write meeting notes from a machine-generated transcript.

    Speakers: "Me" is the user, recorded from their microphone. Other lines are labeled with the \
    participant the call app showed as talking, or "Others" when that wasn't available (which may \
    be several people). Speaker labels can occasionally be wrong at turn boundaries.

    The transcript can contain recognition errors. Infer the intended words when context makes \
    them obvious, but never invent facts, decisions, or commitments that weren't said.

    Write Markdown, in the language the meeting was held in:
    # <a short, specific title for the meeting>
    ## Summary
    Two to four sentences.
    ## Key points
    ## Decisions
    ## Action items
    Use "- [ ] Owner: task", where Owner is "Me", a name from the transcript, or "Unassigned".
    ## Open questions

    Leave out any section that would be empty. Output only the notes.
    """

    static func input(for meeting: Meeting) -> String {
        """
        Meeting: \(meeting.title)\(meeting.platform.isEmpty ? "" : " (\(meeting.platform))")
        Started: \(meeting.startedAt.formatted(.iso8601))\(meeting.participants.map { "\nParticipants: " + $0.joined(separator: ", ") } ?? "")
        <transcript>
        \(meeting.transcriptText)
        </transcript>
        """
    }

    /// For a voice note: one speaker thinking aloud.
    static let noteSystem = """
    You turn a voice note into clean written notes. The transcript is machine-generated; it is \
    one person ("Me") thinking aloud. Infer intended words when context makes them obvious, but \
    never invent ideas, decisions, or commitments that weren't said.

    Write Markdown, in the language of the note:
    # <a short, specific title>
    ## Summary
    Two to four sentences capturing the point.
    ## Key points
    ## Action items
    Use "- [ ] Me: task" for things the speaker said they'd do.
    ## Open questions

    Leave out any section that would be empty. Output only the notes.
    """

    func summarize(_ meeting: Meeting) async throws -> String {
        try await cli.run(
            model: "claude-opus-5-5",
            effort: "medium",
            system: meeting.isNote ? Self.noteSystem : Self.system,
            input: Self.input(for: meeting),
            timeout: .seconds(300)
        )
    }
}
