import AppKit
import Sparkle

/// Sparkle auto-updates. Only Release builds carry a feed URL (set in project.yml), so Debug
/// builds never check. A menu-bar app is never frontmost, so a scheduled update alert would open
/// behind other windows: Sparkle holds it back ("gentle reminders") and the tray offers it instead.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    /// Version found by a scheduled check that the user hasn't looked at yet.
    private(set) var pendingVersion: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    var isEnabled: Bool { controller != nil }

    override init() {
        super.init()
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        guard !feed.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    /// Also brings a held-back update to the front instead of starting a new check.
    func check() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle show it only when it can come up in front, such as right after launch.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            if handleShowingUpdate { NSApp.activate() }
            if !userInitiated { pendingVersion = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pendingVersion = nil }
    }
}
