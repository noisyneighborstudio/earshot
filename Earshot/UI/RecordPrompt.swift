import SwiftUI

/// What the record card says when nothing is recording, shared by the tray and the sidebar:
/// a detected call offers "Record Meeting"; otherwise it's a voice note.
@MainActor
enum RecordPrompt {
    static func title(_ model: AppModel) -> String {
        if let call = model.detector.current { return String(localized: "\(call.platform.name) call detected") }
        return String(localized: "Record a note")
    }

    static func subtitle(_ model: AppModel) -> String {
        if let call = model.detector.current {
            return call.title.isEmpty ? String(localized: "Your mic and the call audio") : call.title
        }
        return String(localized: "Your thoughts, summarized by Claude")
    }

    static func buttonTitle(_ model: AppModel) -> LocalizedStringKey {
        model.detector.current == nil ? "Record Note" : "Record Meeting"
    }

    static func buttonImage(_ model: AppModel) -> String {
        model.detector.current == nil ? "mic.fill" : "record.circle"
    }

    /// Only for notes: a call always includes its audio.
    static func showsComputerAudioOption(_ model: AppModel) -> Bool { model.detector.current == nil }
}

/// "Include computer audio" for a note, e.g. a call in an app Earshot doesn't recognize.
struct ComputerAudioToggle: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle("Include computer audio", isOn: $settings.noteIncludesComputerAudio)
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(Text("Also record what your Mac plays, for calls in apps Earshot doesn't detect"))
    }
}
