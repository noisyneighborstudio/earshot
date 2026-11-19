import Foundation
import os
import UserNotifications

/// "Notes ready" notifications. (A detected call is offered in the floating pill instead:
/// macOS hides banners while the screen is shared.)
@MainActor
final class Notifier: NSObject {
    var onOpenMeeting: ((Meeting.ID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "notifications")

    override init() {
        super.init()
        center.delegate = self
    }

    func notesReady(_ meeting: Meeting) {
        let content = UNMutableNotificationContent()
        content.title = meeting.summaryError == nil
            ? String(localized: "Meeting notes ready")
            : String(localized: "Meeting saved, notes incomplete")
        var details = [meeting.title]
        if let duration = meeting.duration { details.append(String(localized: "\(max(1, Int(duration / 60))) min")) }
        if meeting.openTaskCount > 0 { details.append(String(localized: "\(meeting.openTaskCount) action items")) }
        content.body = details.joined(separator: " · ")
        content.userInfo = ["meeting": meeting.id.uuidString]
        post(UNNotificationRequest(identifier: meeting.id.uuidString, content: content, trigger: nil))
    }

    private func post(_ request: UNNotificationRequest) {
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    log.info("notifications not authorized")
                    return
                }
                try await center.add(request)
            } catch {
                log.error("notification failed: \(error.localizedDescription)")
            }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let meeting = (response.notification.request.content.userInfo["meeting"] as? String).flatMap(UUID.init)
        else { return }
        await MainActor.run { onOpenMeeting?(meeting) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
