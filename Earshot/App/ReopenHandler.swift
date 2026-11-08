import AppKit

/// Launching Earshot again while it's running (Finder, Spotlight, `open`) opens the main window,
/// as Mac apps do; a menu-bar app has no Dock icon to click otherwise.
@MainActor
final class ReopenHandler: NSObject {
    private let onReopen: @MainActor () -> Void

    init(onReopen: @escaping @MainActor () -> Void) {
        self.onReopen = onReopen
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handle(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        onReopen()
    }
}
