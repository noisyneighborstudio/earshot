import SwiftUI

@main
struct EarshotApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // Template images from the app icon's mic: macOS tints them for the menu bar.
            Image(model.recorder.state == .recording ? "MenuBarRecording"
                  : model.controller.phase == .idle ? "MenuBarIdle" : "MenuBarDictating")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: model.settings, speech: model.speech, updater: model.updater)
        }
    }
}
