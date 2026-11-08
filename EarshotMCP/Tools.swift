import Foundation
import MCP

/// The MCP surface over `NotesLibrary`. Tool text is model-facing, so English.
enum NotesTools {
    static let instructions = """
        Earshot (NN Earshot) records the user's calls and voice notes on their Mac, transcribes them, and \
        writes markdown notes with action items ("- [ ] Owner: task"). Start with search_notes or \
        list_meetings; then get_meeting for full notes, and its transcript only when you need exact wording \
        (page it with transcript_offset). Dates are the user's local time. A meeting with status "recording" \
        is still being recorded (or was interrupted): its transcript is partial and it has no notes yet.
        """

    private static let filters: [String: Value] = [
        "kind": ["type": "string", "enum": ["meeting", "note"], "description": "meeting = a call; note = a voice note (just the user)."],
        "participant": ["type": "string", "description": "Name, or part of one, of someone who spoke."],
        "platform": ["type": "string", "description": "Call app, e.g. Zoom, Microsoft Teams, Chrome."],
        "folder": ["type": "string", "description": "Exact folder name."],
        "starred": ["type": "boolean"],
        "status": ["type": "string", "enum": ["recording", "notes_pending", "notes_failed", "ready"]],
        "after": ["type": "string", "description": "Started on or after: 2026-03-14 or ISO 8601 date-time."],
        "before": ["type": "string", "description": "Started before; a bare date includes that whole day."],
    ]

    private static func paging(_ fallback: Int, _ upper: Int) -> [String: Value] {
        [
            "limit": ["type": "integer", "minimum": 1, "maximum": .int(upper), "description": .string("Default \(fallback).")],
            "offset": ["type": "integer", "minimum": 0, "description": "Skip this many; use next_offset from the last page."],
        ]
    }

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    private static let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    static let all: [Tool] = [
        Tool(
            name: "search_notes",
            description: """
                Ranked search across meeting and voice-note titles, people, notes, action items, and transcripts. \
                Hybrid by default: keyword ranking (BM25) fused with on-device semantic similarity, so paraphrases \
                can match too (match = lexical, semantic, or both). Returns meetings with short snippets; \
                transcript snippets include `line` for get_meeting's transcript_offset.
                """,
            inputSchema: schema(filters.merging(paging(10, 50)) { a, _ in a }.merging([
                "query": ["type": "string", "description": "Words or a phrase to look for."],
                "mode": ["type": "string", "enum": ["hybrid", "lexical"], "description": "lexical = keywords only. Default hybrid."],
            ]) { a, _ in a }, required: ["query"]),
            annotations: readOnly),
        Tool(
            name: "list_meetings",
            description: "Meetings and voice notes, newest first, with status, people, and open action-item counts. No notes text; use get_meeting.",
            inputSchema: schema(filters.merging(paging(20, 100)) { a, _ in a }),
            annotations: readOnly),
        Tool(
            name: "get_meeting",
            description: """
                One meeting's metadata and markdown notes. Set include_transcript for the transcript, paged as \
                "[mm:ss] Speaker: text" lines (Me = the user).
                """,
            inputSchema: schema([
                "id": ["type": "string", "description": "Meeting id (or its first 8+ characters)."],
                "include_transcript": ["type": "boolean", "description": "Default false."],
                "transcript_offset": ["type": "integer", "minimum": 0, "description": "First line to return. Default 0."],
                "transcript_limit": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "Default 200."],
            ], required: ["id"]),
            annotations: readOnly),
        Tool(
            name: "list_action_items",
            description: "Action items from meeting notes, newest meeting first. Owner \"Me\" is the user.",
            inputSchema: schema(filters.merging(paging(50, 200)) { a, _ in a }.merging([
                "state": ["type": "string", "enum": ["open", "done", "all"], "description": "Default open."],
                "owner": ["type": "string", "description": "Owner name, or part of one (\"Me\" = the user, \"Unassigned\")."],
                "meeting_id": ["type": "string", "description": "Only this meeting's items."],
            ]) { a, _ in a }),
            annotations: readOnly),
        Tool(
            name: "search_dictations",
            description: "The user's recent dictations (text Earshot typed into apps), newest first.",
            inputSchema: schema(paging(20, 200).merging([
                "query": ["type": "string", "description": "Text to look for. Omit to list recent dictations."],
                "app": ["type": "string", "description": "App dictated into, or part of its name."],
                "after": ["type": "string", "description": "On or after: 2026-03-14 or ISO 8601 date-time."],
                "before": ["type": "string", "description": "Before; a bare date includes that whole day."],
            ]) { a, _ in a }),
            annotations: readOnly),
    ]

    static func call(_ params: CallTool.Parameters, library: NotesLibrary) async -> CallTool.Result {
        do {
            let data = try JSONEncoder().encode(params.arguments ?? [:])
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let args: ToolArguments
            do {
                args = try decoder.decode(ToolArguments.self, from: data)
            } catch {
                throw NotesError("Invalid arguments: \(NotesLibrary.describe(error)).")
            }
            let text: String = switch params.name {
            case "search_notes": try Output.json(await library.search(args))
            case "list_meetings": try Output.json(await library.list(args))
            case "get_meeting": try Output.json(await library.meeting(args))
            case "list_action_items": try Output.json(await library.actionItems(args))
            case "search_dictations": try Output.json(await library.dictations(args))
            default: throw NotesError("Unknown tool '\(params.name)'.")
            }
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: Resources and prompts

    static let template = Resource.Template(
        uriTemplate: "earshot://meeting/{id}", name: "Meeting",
        description: "A meeting's notes and full transcript, as markdown.", mimeType: "text/markdown")

    static func resources(cursor: String?, library: NotesLibrary) async throws -> ListResources.Result {
        let all = try await library.summaries()
        let start = min(Int(cursor ?? "") ?? 0, all.count), end = min(start + 100, all.count)
        return .init(
            resources: all[start..<end].map {
                Resource(name: $0.title, uri: "earshot://meeting/\($0.id.uuidString)",
                         description: "\(Output.date($0.date)) · \($0.kind.rawValue) · \($0.status.rawValue)",
                         mimeType: "text/markdown")
            },
            nextCursor: end < all.count ? String(end) : nil)
    }

    static func read(_ uri: String, library: NotesLibrary) async throws -> ReadResource.Result {
        guard uri.hasPrefix("earshot://meeting/") else { throw MCPError.invalidParams("Unknown resource \(uri)") }
        do {
            return .init(contents: [.text(try await library.markdown(uri), uri: uri, mimeType: "text/markdown")])
        } catch {
            throw MCPError.invalidParams(error.localizedDescription)
        }
    }

    static let brief = Prompt(
        name: "meeting_brief",
        description: "Brief me before a meeting with someone, from past Earshot notes.",
        arguments: [
            .init(name: "person", description: "Who the meeting is with.", required: true),
            .init(name: "topic", description: "What it's about (optional)."),
        ])

    static func prompt(_ params: GetPrompt.Parameters, library: NotesLibrary) async throws -> GetPrompt.Result {
        guard params.name == brief.name else { throw MCPError.invalidParams("Unknown prompt \(params.name)") }
        guard let person = params.arguments?["person"], !person.isEmpty else {
            throw MCPError.invalidParams("`person` is required.")
        }
        let topic = params.arguments?["topic"].flatMap { $0.isEmpty ? nil : $0 }
        do {
            let text = try await library.brief(person: person, topic: topic)
            return .init(description: "Brief for a meeting with \(person)", messages: [.user(.text(text: text))])
        } catch {
            throw MCPError.invalidParams(error.localizedDescription)
        }
    }
}
