import SwiftUI

@main
struct EarshotApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.recorder.state == .recording ? "record.circle"
                  : model.controller.phase == .idle ? "waveform" : "waveform.badge.mic")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: model.settings, speech: model.speech, updater: model.updater)
        }
    }
}
