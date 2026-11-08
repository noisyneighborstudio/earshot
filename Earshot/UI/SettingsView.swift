import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let speech: SpeechEngine
    let updater: Updater

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: $settings.hotkey) {
                    ForEach(Hotkey.allCases) { Text(verbatim: $0.label).tag($0) }
                }
                Picker("Language", selection: $settings.localeIdentifier) {
                    ForEach(localeChoices, id: \.identifier) { locale in
                        Text(verbatim: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                Toggle("Play sounds", isOn: $settings.playSounds)
            } header: {
                Text("Dictation")
            } footer: {
                Text(verbatim: speech.statusDescription + "\n" + String(localized: "Dictation runs entirely on this Mac."))
            }

            Section {
                Picker("When a call starts", selection: $settings.meetingMode) {
                    ForEach(MeetingMode.allCases) { Text(verbatim: $0.label).tag($0) }
                }
            } header: {
                Text("Meetings")
            } footer: {
                Text("Earshot detects calls in Zoom, Teams, FaceTime, Slack, Google Meet and others. Your mic and the call audio are transcribed on this Mac; Claude writes the notes. Recording laws vary — tell participants you're taking notes.")
            }

            Section {
                TextEditor(text: $settings.dictionaryText)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
            } header: {
                Text("Dictionary")
            } footer: {
                Text("One word or phrase per line: names, jargon, product terms. Used for recognition and spelling.")
            }

            AgentsSection()

            if updater.isEnabled {
                Section {
                    LabeledContent("Version") {
                        Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    }
                    Button("Check for Updates…") { updater.check() }
                } header: {
                    Text("Updates")
                }
            }

            Section {
                Text("If pressing fn opens the emoji picker or starts macOS dictation, set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    /// Keeps the current selection visible even before the supported list has loaded.
    private var localeChoices: [Locale] {
        let current = Locale(identifier: settings.localeIdentifier)
        let supported = speech.supportedLocales
        return supported.contains { $0.identifier == current.identifier } ? supported : [current] + supported
    }
}
