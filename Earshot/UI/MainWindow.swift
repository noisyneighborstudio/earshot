import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home, meetings, actionItems, dictations, dictionary

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .meetings: String(localized: "Meetings")
        case .actionItems: String(localized: "Action Items")
        case .dictations: String(localized: "Dictations")
        case .dictionary: String(localized: "Dictionary")
        }
    }
    var systemImage: String {
        switch self {
        case .home: "house"
        case .meetings: "person.2.wave.2"
        case .actionItems: "checklist"
        case .dictations: "waveform"
        case .dictionary: "character.book.closed"
        }
    }
}

enum MeetingFilter: Hashable, Sendable {
    case all, starred, needsNotes
    case folder(String)
}

/// What the main window shows. Owned by AppModel so the tray and notifications can navigate.
@MainActor
@Observable
final class AppNavigation {
    var section: AppSection = .home
    /// Selected meeting within the Meetings section.
    var meetingID: Meeting.ID?
    var filter: MeetingFilter = .all
    var query = ""
}

/// The single app window (Home, Meetings, Action Items, Dictations, Dictionary). AppKit-owned
/// so it can be opened from the tray and from notifications.
@MainActor
final class MainWindow {
    private var window: NSWindow?
    /// Set by AppModel right after init.
    weak var model: AppModel?

    var isVisible: Bool { window?.isVisible == true }

    func show(section: AppSection? = nil, meeting: Meeting.ID? = nil) {
        guard let model else { return }
        if let section { model.navigation.section = section }
        if let meeting {
            model.navigation.section = .meetings
            model.navigation.meetingID = meeting
        }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model)))
            // Each screen has its own heading, so the title bar shows only the window controls.
            // (The title still names the window in the Window menu and Mission Control.)
            window.title = String(localized: "NN Earshot")
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.setContentSize(NSSize(width: 1140, height: 720))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("Main")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MainView: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            AppSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            switch model.navigation.section {
            case .home: HomeView(model: model)
            case .meetings: MeetingsSection(model: model)
            case .actionItems: ActionItemsView(model: model)
            case .dictations: DictationsView(model: model)
            case .dictionary: DictionaryView(model: model)
            }
        }
    }
}

