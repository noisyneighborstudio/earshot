import SwiftUI

/// Settings › Voice Commands: agent proposals pinned on top, then commands grouped by app. Each row says
/// whether it's yours or learned; clicking one edits it.
struct VoiceCommandsSection: View {
    let commands: VoiceCommands
    let hotkey: Hotkey
    @State private var error: String?
    @State private var editing: ActionLibrary.Entry?
    @State private var search = ""

    var body: some View {
        Group {
            Section {
                TextField("Search", text: $search, prompt: Text("Search commands and phrases"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }

            if !commands.proposals.isEmpty {
                Section {
                    ForEach(commands.proposals) { proposal in
                        CommandRow(entry: proposal, collisions: commands.collisions(proposal)) {
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

            ForEach(groups, id: \.app) { group in
                Section {
                    ForEach(group.entries) { entry in
                        CommandRow(entry: entry, collisions: []) { EmptyView() }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = entry }
                            .contextMenu {
                                Button("Edit…") { editing = entry }
                                Button("Edit as JSON…") { NSWorkspace.shared.open(entry.file) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.file]) }
                                Divider()
                                Button("Delete", role: .destructive) { attempt { try commands.remove(entry) } }
                            }
                    }
                } header: {
                    AppLabel(bundleID: group.app)
                }
            }

            Section {
                ForEach(commands.invalid) { file in
                    LabeledContent {
                        Text(verbatim: file.problem).foregroundStyle(.red)
                    } label: {
                        Text(verbatim: file.file.lastPathComponent)
                    }
                }
                if commands.actions.isEmpty && commands.invalid.isEmpty {
                    Text("No commands yet. Say “make an action …”, or tap Remember after Claude figures one out.")
                        .foregroundStyle(.secondary)
                } else if groups.isEmpty {
                    Text("No commands match “\(search)”.").foregroundStyle(.secondary)
                }
                if let error {
                    Text(verbatim: error).foregroundStyle(.red)
                }
                Button("Open Actions Folder") { commands.revealFolder() }
            } footer: {
                Text("Hold \(hotkey.shortLabel) + ⌃ and say a command. Menu items in the frontmost app (“save”, “add bookmark”), “open Safari” and “go to example.com” work without setup. When Claude works out what you meant, tap Remember to keep the phrase; saying it a second time keeps it too.")
            }
        }
        .onAppear {
            commands.reload()
            commands.markLearnedSeen()
            openRequested()
        }
        .onChange(of: commands.editRequest) { openRequested() }
        .sheet(item: $editing) { entry in
            ActionEditor(entry: entry, commands: commands)
        }
    }

    /// Edit on the overlay after making an action by voice.
    private func openRequested() {
        guard let file = commands.editRequest else { return }
        commands.editRequest = nil
        editing = (commands.actions + commands.proposals).first { $0.file == file }
    }

    /// Everywhere first, then apps by name.
    private var groups: [(app: String, entries: [ActionLibrary.Entry])] {
        let query = Phrase.normalize(search)
        let shown = commands.actions.filter { entry in
            query.isEmpty || ([entry.action.name] + entry.action.phrases + [Apps.name(entry.action.when?.app ?? "") ?? ""])
                .contains { Phrase.normalize($0).contains(query) }
        }
        let byApp = Dictionary(grouping: shown) { $0.action.when?.app?.lowercased() ?? "" }
        return byApp.keys
            .sorted { a, b in a.isEmpty || (!b.isEmpty && (Apps.name(a) ?? a).localizedStandardCompare(Apps.name(b) ?? b) == .orderedAscending) }
            .map { ($0, byApp[$0]!.sorted { $0.action.name.localizedStandardCompare($1.action.name) == .orderedAscending }) }
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

/// An app's icon and name from its bundle ID; "Everywhere" for none.
private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        if bundleID.isEmpty {
            Label("Everywhere", systemImage: "globe")
        } else {
            Label {
                Text(verbatim: Apps.name(bundleID) ?? bundleID)
            } icon: {
                if let icon = Apps.icon(bundleID) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
            }
        }
    }
}

private struct CommandRow<Buttons: View>: View {
    let entry: ActionLibrary.Entry
    let collisions: [String]
    @ViewBuilder let buttons: Buttons
    private var action: VoiceAction { entry.action }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: action.name).fontWeight(.semibold)
                Text(phrases)
                Text(verbatim: action.steps.map(StepText.describe).joined(separator: String(localized: ", then ")))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
            Spacer()
            buttons
            if Buttons.self == EmptyView.self {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Yours in the primary color, learned ones quieter.
    private var phrases: AttributedString {
        var text = AttributedString()
        for (index, phrase) in action.phrases.enumerated() {
            if index > 0 { text += AttributedString(", ") }
            var part = AttributedString("“\(phrase)”")
            part.foregroundColor = index < action.say.count ? .primary : .secondary
            text += part
        }
        return text
    }

    private var caption: String {
        guard action.isLearned else { return String(localized: "Yours") }
        if Calendar.current.isDateInToday(entry.modified) { return String(localized: "Learned today") }
        return String(localized: "Learned \(entry.modified.formatted(.dateTime.month(.abbreviated).day()))")
    }
}

enum StepText {
    static func describe(_ step: VoiceAction.Step) -> String {
        switch step {
        case .openApp(let app): String(localized: "Open \(app)")
        case .openURL(let url): String(localized: "Open \(url)")
        case .keystroke(let keys): String(localized: "Press \(Keystroke(keys)?.symbols ?? keys)")
        case .menu(let path): path.joined(separator: " › ")
        case .shortcut(let name): String(localized: "Run shortcut “\(name)”")
        }
    }
}

extension Keystroke {
    /// ⌘⇧D, ⌥↩, F5.
    var symbols: String {
        let order: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let names = ["return": "↩", "tab": "⇥", "space": "Space", "escape": "⎋", "delete": "⌫",
                     "left": "←", "right": "→", "up": "↑", "down": "↓"]
        return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + (names[key] ?? key.uppercased())
    }
}

/// Installed apps by bundle ID, for names, icons and the editor's app menus.
@MainActor
enum Apps {
    struct App: Hashable { let name: String; let bundleID: String }

    static func name(_ bundleID: String) -> String? {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    static func icon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    static let installed: [App] = CommandMatcher.installedApps().values.compactMap { url in
        Bundle(url: url)?.bundleIdentifier.map { App(name: url.deletingPathExtension().lastPathComponent, bundleID: $0) }
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// Edits one command: its phrases (yours and learned), where it works, and what it does.
private struct ActionEditor: View {
    let entry: ActionLibrary.Entry
    let commands: VoiceCommands
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var phrases: [PhraseLine]
    @State private var app: String
    @State private var url: String
    @State private var pagesOnly: Bool
    @State private var steps: [StepLine]
    @State private var shortcuts: [String] = []
    @State private var error: String?

    struct PhraseLine: Identifiable {
        let id = UUID()
        var text: String
        var learned: Bool
    }

    struct StepLine: Identifiable {
        enum Kind: CaseIterable { case menu, keystroke, openApp, openURL, shortcut }
        let id = UUID()
        var kind: Kind
        var value: String
    }

    init(entry: ActionLibrary.Entry, commands: VoiceCommands) {
        self.entry = entry
        self.commands = commands
        let action = entry.action
        _name = State(initialValue: action.name)
        _phrases = State(initialValue: action.say.map { PhraseLine(text: $0, learned: false) }
            + action.learned.map { PhraseLine(text: $0, learned: true) })
        _app = State(initialValue: action.when?.app ?? "")
        _url = State(initialValue: action.when?.url ?? "")
        _pagesOnly = State(initialValue: action.when?.url != nil)
        _steps = State(initialValue: action.steps.map(Self.line))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section {
                    if let builtIn {
                        LabeledContent {
                            Text("built in").foregroundStyle(.secondary)
                        } label: {
                            Text(verbatim: "“\(builtIn)”")
                        }
                    }
                    ForEach($phrases) { $phrase in
                        HStack {
                            TextField("Phrase", text: $phrase.text, prompt: Text("search hacker news for {query}"))
                                .labelsHidden()
                                // Editing a learned phrase makes it yours.
                                .onChange(of: phrase.text) { phrase.learned = false }
                            if phrase.learned { Text("learned").font(.caption).foregroundStyle(.secondary) }
                            remove { phrases.removeAll { $0.id == phrase.id } }
                        }
                    }
                    Button("Add Phrase") { phrases.append(PhraseLine(text: "", learned: false)) }
                } header: {
                    Text("Say")
                } footer: {
                    Text("Any of these runs it. {name} captures words for the steps to use, e.g. {query}.")
                }
                Section {
                    Picker("Works in", selection: $app) {
                        Text("Any app").tag("")
                        Divider()
                        ForEach(appChoices, id: \.bundleID) { choice in
                            Text(verbatim: choice.name).tag(choice.bundleID)
                        }
                    }
                    Toggle("Only on certain pages", isOn: $pagesOnly)
                    if pagesOnly {
                        TextField("Page", text: $url, prompt: Text(verbatim: "*://news.ycombinator.com/*"))
                    }
                } footer: {
                    if pagesOnly { Text("The window's web address or file; * matches anything.") }
                }
                Section {
                    ForEach($steps) { $step in
                        HStack {
                            Picker("Step", selection: $step.kind) {
                                ForEach(StepLine.Kind.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: step.kind) { step.value = "" }
                            value($step)
                            remove { steps.removeAll { $0.id == step.id } }
                        }
                    }
                    Button("Add Step") { steps.append(StepLine(kind: .keystroke, value: "")) }
                } header: {
                    Text("Then")
                }
                if !collisions.isEmpty {
                    Label {
                        Text("Also said for: \(collisions.joined(separator: ", "))")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
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
        .frame(width: 540, height: 600)
        .task { shortcuts = await Self.loadShortcuts() }
    }

    @ViewBuilder
    private func value(_ step: Binding<StepLine>) -> some View {
        switch step.wrappedValue.kind {
        case .keystroke:
            KeyRecorder(keys: step.value)
        case .openApp:
            choices(Apps.installed.map(\.name), selection: step.value)
        case .shortcut where !shortcuts.isEmpty:
            choices(shortcuts, selection: step.value)
        default:
            TextField("Value", text: step.value, prompt: Text(Self.prompt(step.wrappedValue.kind))).labelsHidden()
        }
    }

    /// A menu of names that keeps the current value even if it's not among them.
    private func choices(_ names: [String], selection: Binding<String>) -> some View {
        Picker("Value", selection: selection) {
            if !names.contains(selection.wrappedValue) {
                Text(verbatim: selection.wrappedValue.isEmpty ? String(localized: "Choose…") : selection.wrappedValue)
                    .tag(selection.wrappedValue)
            }
            ForEach(names, id: \.self) { Text(verbatim: $0).tag($0) }
        }
        .labelsHidden()
    }

    /// The menu item's own title already works for a single menu step.
    private var builtIn: String? {
        guard steps.count == 1, case .menu(let path)? = action.steps.first else { return nil }
        return path.last
    }

    /// Installed apps, plus the current one if it isn't installed.
    private var appChoices: [Apps.App] {
        guard !app.isEmpty, !Apps.installed.contains(where: { $0.bundleID == app }) else { return Apps.installed }
        return [Apps.App(name: app, bundleID: app)] + Apps.installed
    }

    private var collisions: [String] {
        commands.library.collisions(action, with: commands.actions.filter { $0.file != entry.file })
    }

    private var action: VoiceAction {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespaces) }
        let page = pagesOnly && !trim(url).isEmpty ? trim(url) : nil
        let scope = VoiceAction.Scope(app: app.isEmpty ? nil : app, url: page)
        let lines = phrases.map { (learned: $0.learned, text: trim($0.text)) }.filter { !$0.text.isEmpty }
        return VoiceAction(
            name: trim(name),
            say: lines.filter { !$0.learned }.map(\.text),
            learned: lines.filter(\.learned).map(\.text),
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

    private static func loadShortcuts() async -> [String] {
        await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [String]() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
        }.value
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
        case .menu: "Choose menu item"
        case .keystroke: "Press keys"
        case .openApp: "Open app"
        case .openURL: "Open link"
        case .shortcut: "Run shortcut"
        }
    }

    private static func prompt(_ kind: StepLine.Kind) -> String {
        switch kind {
        case .menu: String(localized: "File › Export as PDF…")
        case .openURL: String(localized: "https://news.ycombinator.com/search?q={query}")
        case .shortcut: String(localized: "Shortcut name")
        case .keystroke, .openApp: ""
        }
    }
}

/// Click, then press the keys; stored as "cmd+shift+d".
private struct KeyRecorder: View {
    @Binding var keys: String
    @State private var monitor: Any?

    var body: some View {
        Button {
            monitor == nil ? start() : stop()
        } label: {
            Text(verbatim: monitor != nil ? String(localized: "Press keys…")
                 : keys.isEmpty ? String(localized: "Record Keys") : Keystroke(keys)?.symbols ?? keys)
                .frame(minWidth: 120)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let recorded = Self.keystroke(event) { keys = recorded }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static let named: [UInt16: String] = [36: "return", 48: "tab", 49: "space", 53: "escape", 51: "delete",
        123: "left", 124: "right", 125: "down", 126: "up", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5",
        97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]

    /// "cmd+shift+d" from a key press, or nil for one Keystroke can't express.
    static func keystroke(_ event: NSEvent) -> String? {
        guard let key = named[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased(),
              key.count == 1 || named.values.contains(key), key != "+" else { return nil }
        let flags = event.modifierFlags
        let parts = [(flags.contains(.control), "ctrl"), (flags.contains(.option), "opt"),
                     (flags.contains(.shift), "shift"), (flags.contains(.command), "cmd")].filter(\.0).map(\.1)
        return (parts + [key]).joined(separator: "+")
    }
}
