import Foundation
import os
import UserNotifications

/// "Call detected — take notes?" and "Notes ready" notifications.
@MainActor
final class Notifier: NSObject {
    var onTakeNotes: (() -> Void)?
    var onOpenMeeting: ((Meeting.ID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "studio.noisyneighbor.earshot", category: "notifications")
    private static let callCategory = "call"
    private static let callRequest = "call-detected"
    private static let takeNotesAction = "take-notes"

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.callCategory,
                actions: [
                    UNNotificationAction(identifier: Self.takeNotesAction, title: String(localized: "Record Meeting"), options: []),
                    UNNotificationAction(identifier: "not-now", title: String(localized: "Not Now"), options: []),
                ],
                intentIdentifiers: [])
        ])
    }

    func callDetected(_ call: DetectedCall) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(call.platform.name) call detected")
        content.body = String(localized: "Record and summarize it with Earshot? Let others know you're transcribing.")
        content.categoryIdentifier = Self.callCategory
        post(UNNotificationRequest(identifier: Self.callRequest, content: content, trigger: nil))
    }

    func clearCallPrompt() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.callRequest])
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
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let meeting = (response.notification.request.content.userInfo["meeting"] as? String).flatMap(UUID.init)
        await MainActor.run {
            if category == Self.callCategory, action == Self.takeNotesAction || action == UNNotificationDefaultActionIdentifier {
                onTakeNotes?()
            } else if let meeting {
                onOpenMeeting?(meeting)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
