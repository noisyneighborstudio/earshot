import Foundation
import MCP

// earshot-mcp: a read-only stdio MCP server over NN Earshot's meetings, notes, and dictations.
// `--data-dir <dir>` (tests only) reads <dir>/Meetings and <dir>/history.json instead of the app's.
var arguments = Array(CommandLine.arguments.dropFirst())
var directory = EarshotData.directory
if arguments.first == "--data-dir", arguments.count == 2 {
    directory = URL(filePath: arguments[1], directoryHint: .isDirectory)
    arguments.removeAll()
}
guard arguments.isEmpty else {
    FileHandle.standardError.write(Data("usage: earshot-mcp\nA stdio MCP server; add it to your agent (see NN Earshot › Settings).\n".utf8))
    exit(64)
}

let library = NotesLibrary(directory: directory)
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let server = Server(
    name: "earshot", version: version, title: "NN Earshot", instructions: NotesTools.instructions,
    capabilities: .init(prompts: .init(listChanged: false), resources: .init(subscribe: false, listChanged: false),
                        tools: .init(listChanged: false)))

await server.withMethodHandler(ListTools.self) { _ in .init(tools: NotesTools.all) }
await server.withMethodHandler(CallTool.self) { await NotesTools.call($0, library: library) }
await server.withMethodHandler(ListResources.self) { try await NotesTools.resources(cursor: $0.cursor, library: library) }
await server.withMethodHandler(ListResourceTemplates.self) { _ in .init(templates: [NotesTools.template]) }
await server.withMethodHandler(ReadResource.self) { try await NotesTools.read($0.uri, library: library) }
await server.withMethodHandler(ListPrompts.self) { _ in .init(prompts: [NotesTools.brief]) }
await server.withMethodHandler(GetPrompt.self) { try await NotesTools.prompt($0, library: library) }

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
