import AppKit
import Foundation

/// How agents launch the bundled earshot-mcp helper. Pure, so it's testable.
enum AgentSetup {
    static let serverName = "earshot"

    enum Placement: Equatable {
        case ok
        /// Gatekeeper runs quarantined downloads from a random read-only path.
        case translocated
        /// Downloads, a disk image, DerivedData: the path breaks once the app moves.
        case outsideApplications
    }

    static func placement(of app: URL, home: URL = URL.homeDirectory) -> Placement {
        let path = app.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .translocated }
        let roots = ["/Applications/", home.appending(path: "Applications").standardizedFileURL.path + "/"]
        return roots.contains { path.hasPrefix($0) } ? .ok : .outsideApplications
    }

    static func helper(in app: URL) -> URL { app.appending(path: "Contents/MacOS/earshot-mcp") }

    static func claudeAdd(_ helper: URL) -> [String] { ["mcp", "add", "--scope", "user", serverName, "--", helper.path] }
    static let claudeGet = ["mcp", "get", serverName]
    static let claudeRemove = ["mcp", "remove", "--scope", "user", serverName]
    static func codexAdd(_ helper: URL) -> [String] { ["mcp", "add", serverName, "--", helper.path] }
    static let codexGet = ["mcp", "get", serverName]
    static let codexRemove = ["mcp", "remove", serverName]

    /// cursor.com/docs/context/mcp/install-links: `config` is base64 of the mcp.json server entry.
    static func cursorURL(_ helper: URL) -> URL {
        let config = Data(json(["command": helper.path]).utf8).base64EncodedString()
        return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=\(serverName)&config="
            + config.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }

    /// code.visualstudio.com MCP docs: `vscode:mcp/install?` + encodeURIComponent(JSON).
    static func vsCodeURL(_ helper: URL) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        return URL(string: "vscode:mcp/install?"
            + json(["name": serverName, "command": helper.path]).addingPercentEncoding(withAllowedCharacters: allowed)!)!
    }

    /// The `mcpServers` config most agents (Claude Desktop, Cursor, Windsurf, …) read.
    static func jsonConfig(_ helper: URL) -> String {
        json(["mcpServers": [serverName: ["command": helper.path]]], pretty: true)
    }

    /// The launch command, quoted for a shell.
    static func command(_ helper: URL) -> String { "\"\(helper.path)\"" }

    /// Claude Desktop extension manifest (github.com/modelcontextprotocol/mcpb, MANIFEST.md).
    static func mcpbManifest(version: String) -> String {
        json([
            "manifest_version": "0.3",
            "name": serverName,
            "display_name": "NN Earshot",
            "version": version,
            "description": "Search your Earshot meeting notes, transcripts, action items, and dictations. Read-only, on this Mac.",
            "author": ["name": "Noisy Neighbor", "url": "https://noisyneighbor.studio"],
            "icon": "icon.png",
            "server": [
                "type": "binary",
                "entry_point": "server/earshot",
                "mcp_config": ["command": "${__dirname}/server/earshot", "args": [String]()],
            ],
            "compatibility": ["platforms": ["darwin"]],
        ], pretty: true)
    }

    /// The extension's server: execs the app's helper, so Sparkle updates reach Claude Desktop too.
    static func mcpbLauncher(_ helper: URL) -> String {
        "#!/bin/sh\nexec '\(helper.path.replacingOccurrences(of: "'", with: "'\\''"))' \"$@\"\n"
    }

    /// Claude Desktop records installed extensions here, keyed by an id ending in the manifest name.
    static func mcpbStatus(installations: Data) -> Status {
        let object = try? JSONSerialization.jsonObject(with: installations) as? [String: Any]
        let ids = (object?["extensions"] as? [String: Any])?.keys ?? [:].keys
        return ids.contains { $0 == serverName || $0.hasSuffix(".\(serverName)") } ? .connected : .notConnected
    }

    static let claudeDesktopInstallations = URL.applicationSupportDirectory.appending(path: "Claude/extensions-installations.json")
    static let cursorConfig = URL.homeDirectory.appending(path: ".cursor/mcp.json")
    static let vsCodeConfig = URL.applicationSupportDirectory.appending(path: "Code/User/mcp.json")

    enum Status: Equatable {
        case missing, notConnected, connected, connectedElsewhere
    }

    /// Whether config text points at this helper, another copy of it, or neither.
    static func status(ofConfig text: String, helper: URL) -> Status {
        let path = helper.path
        if text.contains(path) || text.contains(path.replacingOccurrences(of: "/", with: "\\/")) { return .connected }
        return text.contains("earshot-mcp") ? .connectedElsewhere : .notConnected
    }

    private static func json(_ value: Any, pretty: Bool = false) -> String {
        let options: JSONSerialization.WritingOptions = pretty
            ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: options), as: UTF8.self)
    }
}

/// Connects agents to Earshot's notes: runs their CLIs, opens their install links, or copies config.
@MainActor
@Observable
final class AgentConnections {
    enum Agent: String, CaseIterable, Identifiable {
        case claudeCode, codex, cursor, vsCode, claudeDesktop
        var id: Self { self }

        var name: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .cursor: "Cursor"
            case .vsCode: "VS Code"
            case .claudeDesktop: "Claude Desktop"
            }
        }

        var canRemove: Bool { self == .claudeCode || self == .codex }
    }

    private(set) var statuses: [Agent: AgentSetup.Status] = [:]
    private(set) var busy: Agent?
    /// The last failure, verbatim from the agent's CLI where there is one.
    var error: String?

    let app = Bundle.main.bundleURL
    var helper: URL { AgentSetup.helper(in: app) }
    var placement: AgentSetup.Placement { AgentSetup.placement(of: app) }

    @ObservationIgnored private var loginPath: String?

    func refresh() async {
        for agent in Agent.allCases {
            do {
                statuses[agent] = try await status(agent)
            } catch {
                self.error = "\(agent.name): \(error.localizedDescription)"
            }
        }
    }

    func install(_ agent: Agent) async {
        await perform(agent) {
            switch agent {
            case .claudeCode:
                let cli = try self.claude()
                if self.isConfigured(agent) { try await self.run(cli, AgentSetup.claudeRemove) }
                try await self.run(cli, AgentSetup.claudeAdd(self.helper))
            case .codex:
                let cli = try await self.codex()
                if self.isConfigured(agent) { try await self.run(cli, AgentSetup.codexRemove) }
                try await self.run(cli, AgentSetup.codexAdd(self.helper))
            case .cursor:
                try self.open(AgentSetup.cursorURL(self.helper), agent)
            case .vsCode:
                try self.open(AgentSetup.vsCodeURL(self.helper), agent)
            case .claudeDesktop:
                try self.open(try await self.writeExtension(), agent)
            }
        }
    }

    func remove(_ agent: Agent) async {
        await perform(agent) {
            switch agent {
            case .claudeCode: try await self.run(try self.claude(), AgentSetup.claudeRemove)
            case .codex: try await self.run(try await self.codex(), AgentSetup.codexRemove)
            case .cursor, .vsCode, .claudeDesktop: break
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func isConfigured(_ agent: Agent) -> Bool {
        statuses[agent] == .connected || statuses[agent] == .connectedElsewhere
    }

    private func perform(_ agent: Agent, _ work: @escaping () async throws -> Void) async {
        guard busy == nil else { return }
        busy = agent
        error = nil
        defer { busy = nil }
        do {
            try await work()
            statuses[agent] = try await status(agent)
        } catch {
            self.error = "\(agent.name): \(error.localizedDescription)"
        }
    }

    private func status(_ agent: Agent) async throws -> AgentSetup.Status {
        switch agent {
        case .claudeCode:
            guard let cli = ClaudeCLI.locate()?.executable else { return .missing }
            return try await cliStatus(cli, AgentSetup.claudeGet, environment: nil)
        case .codex:
            guard let cli = try await locateCodex() else { return .missing }
            return try await cliStatus(cli, AgentSetup.codexGet, environment: try await codexEnvironment())
        case .cursor:
            return try fileStatus(AgentSetup.cursorConfig, app: NSWorkspace.shared.urlForApplication(toOpen: URL(string: "cursor://")!))
        case .vsCode:
            return try fileStatus(AgentSetup.vsCodeConfig, app: NSWorkspace.shared.urlForApplication(toOpen: URL(string: "vscode:")!))
        case .claudeDesktop:
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil else { return .missing }
            guard FileManager.default.fileExists(atPath: AgentSetup.claudeDesktopInstallations.path) else { return .notConnected }
            return AgentSetup.mcpbStatus(installations: try Data(contentsOf: AgentSetup.claudeDesktopInstallations))
        }
    }

    /// `mcp get` exits non-zero when the server isn't configured.
    private func cliStatus(_ cli: URL, _ arguments: [String], environment: [String: String]?) async throws -> AgentSetup.Status {
        let output = try await Subprocess.run(cli, arguments, environment: environment, directory: .homeDirectory, timeout: .seconds(60))
        guard output.status == 0 else { return .notConnected }
        return AgentSetup.status(ofConfig: String(decoding: output.stdout, as: UTF8.self), helper: helper)
    }

    private func fileStatus(_ config: URL, app: URL?) throws -> AgentSetup.Status {
        guard app != nil else { return .missing }
        guard FileManager.default.fileExists(atPath: config.path) else { return .notConnected }
        return AgentSetup.status(ofConfig: try String(contentsOf: config, encoding: .utf8), helper: helper)
    }

    private func claude() throws -> URL {
        guard let cli = ClaudeCLI.locate()?.executable else { throw ClaudeCLIError.notFound }
        return cli
    }

    private func codex() async throws -> URL {
        guard let cli = try await locateCodex() else { throw AgentError(String(localized: "Codex CLI not found.")) }
        return cli
    }

    private func run(_ cli: URL, _ arguments: [String]) async throws {
        let environment = cli.lastPathComponent == "codex" ? try await codexEnvironment() : nil
        let output = try await Subprocess.run(cli, arguments, environment: environment, directory: .homeDirectory, timeout: .seconds(60))
        guard output.status == 0 else { throw AgentError(output.message) }
    }

    /// Builds Earshot.mcpb (a zip with manifest.json at its root) for Claude Desktop to install.
    private func writeExtension() async throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "earshot-mcpb-\(UUID().uuidString)")
        let staging = root.appending(path: "bundle")
        try fm.createDirectory(at: staging.appending(path: "server"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        try Data(AgentSetup.mcpbManifest(version: version).utf8).write(to: staging.appending(path: "manifest.json"))
        let launcher = staging.appending(path: "server/earshot")
        try Data(AgentSetup.mcpbLauncher(helper).utf8).write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        guard let tiff = NSApp.applicationIconImage.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw AgentError(String(localized: "Couldn't render Earshot's icon for the extension.")) }
        try png.write(to: staging.appending(path: "icon.png"))
        let bundle = root.appending(path: "NN Earshot.mcpb")
        let zip = try await Subprocess.run(
            URL(filePath: "/usr/bin/ditto"), ["-c", "-k", "--norsrc", staging.path, bundle.path], timeout: .seconds(30))
        guard zip.status == 0 else { throw AgentError(zip.message) }
        return bundle
    }

    private func open(_ url: URL, _ agent: Agent) throws {
        guard NSWorkspace.shared.open(url) else {
            throw AgentError(String(localized: "Couldn't open \(agent.name)'s install link."))
        }
    }

    // MARK: Codex

    /// Codex usually comes from npm, so it lives on the shell's PATH (and needs node from it),
    /// which GUI apps don't inherit.
    private func locateCodex() async throws -> URL? {
        try await shellPath().split(separator: ":")
            .map { URL(filePath: String($0)).appending(path: "codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func codexEnvironment() async throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = try await shellPath()
        return environment
    }

    private func shellPath() async throws -> String {
        if let loginPath { return loginPath }
        let shell = String(cString: getpwuid(getuid()).pointee.pw_shell)
        let marker = "__EARSHOT_PATH__"
        // Interactive login shell, so rc-file PATH setup (mise, nvm, …) runs; the marker skips rc noise.
        let output = try await Subprocess.run(
            URL(filePath: shell), ["-l", "-i", "-c", "printf '%s%s' \(marker) \"$PATH\""], timeout: .seconds(20))
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard output.status == 0, let range = text.range(of: marker, options: .backwards) else {
            throw AgentError(String(localized: "Couldn't read PATH from \(shell): \(output.message)"))
        }
        let path = String(text[range.upperBound...])
        loginPath = path
        return path
    }
}

struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
