import SwiftUI

/// Settings › Voice Commands: proposals to approve, and the user's actions, each editable.
struct VoiceCommandsSection: View {
    let commands: VoiceCommands
    let hotkey: Hotkey
    @State private var error: String?
    @State private var editing: ActionLibrary.Entry?

    var body: some View {
        Group {
            if !commands.proposals.isEmpty {
                Section {
                    ForEach(commands.proposals) { proposal in
                        ActionRow(action: proposal.action, collisions: commands.collisions(proposal)) {
                            Button("Edit…") { editing = proposal }
                            Button("Discard") { attempt { try commands.remove(proposal) } }
                            Button("Approve") { attempt { try commands.approve(proposal) } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    Text("\(commands.proposals.count) to review")
                } footer: {
                    Text("Proposed by connected agents. They don't run until approved.")
                }
            }

            Section {
                ForEach(commands.actions) { entry in
                    ActionRow(action: entry.action, collisions: []) {
                        Button("Edit…") { editing = entry }
                    }
                }
                ForEach(commands.invalid) { file in
                    LabeledContent {
                        Text(verbatim: file.problem).foregroundStyle(.red)
                    } label: {
                        Text(verbatim: file.file.lastPathComponent)
                    }
                }
                if commands.actions.isEmpty && commands.invalid.isEmpty {
                    Text("No actions yet. Commands Claude figures out are remembered here.").foregroundStyle(.secondary)
                }
                if let error {
                    Text(verbatim: error).foregroundStyle(.red)
                }
                Button("Open Actions Folder") { commands.revealFolder() }
            } header: {
                Text("Actions")
            } footer: {
                Text("Hold \(hotkey.shortLabel) + ⌃ and say a command. Any menu item in the frontmost app works (“save”, “add bookmark”), and so do “open Safari” and “go to example.com”. Say “make an action …” to create your own; agents connected to Earshot can propose them too.")
            }
        }
        .onAppear { commands.reload() }
        .sheet(item: $editing) { entry in
            ActionEditor(entry: entry, commands: commands)
        }
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

/// Edits one action's name, phrases, scope and steps; saved back to its file.
private struct ActionEditor: View {
    let entry: ActionLibrary.Entry
    let commands: VoiceCommands
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var phrases: [Line]
    @State private var app: String
    @State private var url: String
    @State private var steps: [StepLine]
    @State private var error: String?

    struct Line: Identifiable { let id = UUID(); var text: String }

    struct StepLine: Identifiable {
        enum Kind: CaseIterable { case openApp, openURL, keystroke, menu, shortcut }
        let id = UUID()
        var kind: Kind
        var value: String
    }

    init(entry: ActionLibrary.Entry, commands: VoiceCommands) {
        self.entry = entry
        self.commands = commands
        let action = entry.action
        _name = State(initialValue: action.name)
        _phrases = State(initialValue: action.say.map { Line(text: $0) })
        _app = State(initialValue: action.when?.app ?? "")
        _url = State(initialValue: action.when?.url ?? "")
        _steps = State(initialValue: action.steps.map(Self.line))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section {
                    ForEach($phrases) { $phrase in
                        HStack {
                            TextField("Phrase", text: $phrase.text, prompt: Text("search hacker news for {query}"))
                                .labelsHidden()
                            remove { phrases.removeAll { $0.id == phrase.id } }
                        }
                    }
                    Button("Add Phrase") { phrases.append(Line(text: "")) }
                } header: {
                    Text("Phrases")
                } footer: {
                    Text("Any of these runs the action. {name} captures words for the steps to use.")
                }
                Section {
                    TextField("App", text: $app, prompt: Text("Any app (e.g. com.apple.Safari)"))
                    TextField("Page or file", text: $url, prompt: Text("Any (e.g. *://news.ycombinator.com/*)"))
                } header: {
                    Text("Where")
                } footer: {
                    Text("App is a bundle identifier. Page or file is a pattern for the window's URL; * matches anything.")
                }
                Section {
                    ForEach($steps) { $step in
                        HStack {
                            Picker("Step", selection: $step.kind) {
                                ForEach(StepLine.Kind.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("Value", text: $step.value, prompt: Text(Self.prompt(step.kind)))
                                .labelsHidden()
                            remove { steps.removeAll { $0.id == step.id } }
                        }
                    }
                    Button("Add Step") { steps.append(StepLine(kind: .keystroke, value: "")) }
                } header: {
                    Text("Steps")
                }
            }
            .formStyle(.grouped)
            HStack {
                if let error {
                    Text(verbatim: error).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Delete", role: .destructive) { attempt { try commands.remove(entry) } }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { attempt { try commands.save(action, to: entry) } }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    private var action: VoiceAction {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespaces) }
        let scope = VoiceAction.Scope(app: trim(app).isEmpty ? nil : trim(app), url: trim(url).isEmpty ? nil : trim(url))
        return VoiceAction(
            name: trim(name),
            say: phrases.map { trim($0.text) }.filter { !$0.isEmpty },
            when: scope.app == nil && scope.url == nil ? nil : scope,
            steps: steps.map { step in
                let value = trim(step.value)
                switch step.kind {
                case .openApp: return .openApp(value)
                case .openURL: return .openURL(value)
                case .keystroke: return .keystroke(value)
                case .menu: return .menu(value.split(separator: "›").map { trim(String($0)) })
                case .shortcut: return .shortcut(value)
                }
            })
    }

    private func remove(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove"))
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func line(_ step: VoiceAction.Step) -> StepLine {
        switch step {
        case .openApp(let app): StepLine(kind: .openApp, value: app)
        case .openURL(let url): StepLine(kind: .openURL, value: url)
        case .keystroke(let keys): StepLine(kind: .keystroke, value: keys)
        case .menu(let path): StepLine(kind: .menu, value: path.joined(separator: " › "))
        case .shortcut(let name): StepLine(kind: .shortcut, value: name)
        }
    }

    private static func label(_ kind: StepLine.Kind) -> LocalizedStringKey {
        switch kind {
        case .openApp: "Open app"
        case .openURL: "Open URL"
        case .keystroke: "Press keys"
        case .menu: "Choose menu"
        case .shortcut: "Run shortcut"
        }
    }

    private static func prompt(_ kind: StepLine.Kind) -> String {
        switch kind {
        case .openApp: String(localized: "Safari")
        case .openURL: String(localized: "https://news.ycombinator.com/search?q={query}")
        case .keystroke: String(localized: "cmd+shift+d")
        case .menu: String(localized: "File › Export as PDF…")
        case .shortcut: String(localized: "Shortcut name")
        }
    }
}
