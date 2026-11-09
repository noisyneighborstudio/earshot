import SwiftUI

/// Settings › Voice Commands: how to use them, proposals to approve, and the user's actions.
struct VoiceCommandsSection: View {
    let commands: VoiceCommands
    let hotkey: Hotkey
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(commands.proposals) { proposal in
                ActionRow(action: proposal.action, collisions: commands.collisions(proposal)) {
                    Button("Discard") { attempt { try commands.remove(proposal) } }
                    Button("Approve") { attempt { try commands.approve(proposal) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            ForEach(commands.actions) { entry in
                ActionRow(action: entry.action, collisions: []) {
                    Button("Delete", role: .destructive) { attempt { try commands.remove(entry) } }
                }
            }
            ForEach(commands.invalid) { file in
                LabeledContent {
                    Text(verbatim: file.problem).foregroundStyle(.red)
                } label: {
                    Text(verbatim: file.file.lastPathComponent)
                }
            }
            if let error {
                Text(verbatim: error).foregroundStyle(.red)
            }
            Button("Open Actions Folder") { commands.revealFolder() }
        } header: {
            HStack {
                Text("Voice Commands")
                if !commands.proposals.isEmpty {
                    Text("\(commands.proposals.count) to review")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
            }
        } footer: {
            Text("Hold \(hotkey.shortLabel) + ⌃ and say a command. Any menu item in the frontmost app works (“save”, “add bookmark”), and so do “open Safari” and “go to example.com”. Say “make an action …” to create your own; agents connected to Earshot can propose them too. New actions wait here for your approval.")
        }
        .onAppear { commands.reload() }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ActionRow<Buttons: View>: View {
    let action: VoiceAction
    let collisions: [String]
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: action.name).fontWeight(.semibold)
                Spacer()
                buttons
            }
            Text(verbatim: action.say.map { "“\($0)”" }.joined(separator: ", "))
                .foregroundStyle(.secondary)
            Text(verbatim: Self.summary(action))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !collisions.isEmpty {
                Label {
                    Text("Same phrase as: \(collisions.joined(separator: ", "))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private static func summary(_ action: VoiceAction) -> String {
        var parts: [String] = []
        if let app = action.when?.app { parts.append(String(localized: "In \(app)")) }
        if let url = action.when?.url { parts.append(String(localized: "On \(url)")) }
        if parts.isEmpty { parts.append(String(localized: "Everywhere")) }
        let steps = action.steps.map { step -> String in
            switch step {
            case .openApp(let app): String(localized: "open \(app)")
            case .openURL(let url): String(localized: "open \(url)")
            case .keystroke(let keys): String(localized: "press \(keys)")
            case .menu(let path): String(localized: "choose \(path.joined(separator: " › "))")
            case .shortcut(let name): String(localized: "run shortcut \(name)")
            }
        }
        return parts.joined(separator: " · ") + " → " + steps.joined(separator: ", then ")
    }
}
