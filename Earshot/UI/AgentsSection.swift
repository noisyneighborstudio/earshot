import SwiftUI

/// Settings › Connect to Agents: hands Earshot's notes to coding agents over MCP.
struct AgentsSection: View {
    @State private var connections = AgentConnections()

    var body: some View {
        Section {
            if connections.placement == .ok {
                ForEach(AgentConnections.Agent.allCases) { row($0) }
                HStack {
                    Button("Copy JSON Config") { connections.copy(AgentSetup.jsonConfig(connections.helper)) }
                    Button("Copy Command") { connections.copy(AgentSetup.command(connections.helper)) }
                    Spacer()
                    Button("Check Again") { Task { await connections.refresh() } }
                        .disabled(connections.busy != nil)
                }
                if let error = connections.error {
                    Text(verbatim: error)
                        .font(.callout.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else {
                Text(connections.placement == .translocated
                     ? "macOS is running Earshot from a temporary location. Move NN Earshot to your Applications folder and reopen it before connecting agents."
                     : "Move NN Earshot to your Applications folder before connecting agents; agents launch it from its current location.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Connect to Agents")
        } footer: {
            Text("Agents like Claude Code can search your meeting notes, transcripts, action items, and dictations. Read-only, on this Mac. Claude Desktop installs Earshot as an extension; confirm it there.")
        }
        .task { await connections.refresh() }
    }

    private func row(_ agent: AgentConnections.Agent) -> some View {
        let status = connections.statuses[agent]
        return LabeledContent {
            HStack {
                if connections.busy == agent { ProgressView().controlSize(.small) }
                if agent.canRemove, status == .connected || status == .connectedElsewhere {
                    Button("Remove") { Task { await connections.remove(agent) } }
                }
                if status != .missing {
                    Button(status == .notConnected ? "Install" : "Reinstall") {
                        Task { await connections.install(agent) }
                    }
                }
            }
            .disabled(connections.busy != nil || status == nil)
        } label: {
            Text(verbatim: agent.name)
            Text(label(status))
        }
    }

    private func label(_ status: AgentSetup.Status?) -> String {
        switch status {
        case nil: String(localized: "Checking…")
        case .missing: String(localized: "Not installed on this Mac")
        case .notConnected: String(localized: "Not connected")
        case .connected: String(localized: "Connected")
        case .connectedElsewhere: String(localized: "Connected to another copy of Earshot")
        }
    }
}
