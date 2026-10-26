import Foundation
import UserNotifications
import BerthKit

/// Posts user notifications for connection events, with actionable buttons.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String {
        case reconnect = "RECONNECT"
        case updatePassword = "UPDATE_PASSWORD"
        case reveal = "REVEAL"
        case open = "OPEN"
    }

    private enum Category {
        static let mounted = "MOUNTED"
        static let lost = "CONNECTION_LOST"
        static let auth = "AUTH_FAILED"
    }

    var onAction: ((Action, UUID?) -> Void)?
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        let reconnect = UNNotificationAction(identifier: Action.reconnect.rawValue, title: String(localized: "Reconnect"))
        let update = UNNotificationAction(identifier: Action.updatePassword.rawValue, title: String(localized: "Update Password…"), options: [.foreground])
        let reveal = UNNotificationAction(identifier: Action.reveal.rawValue, title: String(localized: "Show in Finder"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.mounted, actions: [reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.lost, actions: [reconnect], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.auth, actions: [update], intentIdentifiers: []),
        ])
        Task { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    func handle(_ event: CoordinatorEvent, preferences: Preferences) {
        switch event {
        case .mounted(let share, let path, let reconnected):
            guard preferences.notifyOnConnect || (reconnected && preferences.notifyOnDisconnect) else { return }
            post(share: share, title: reconnected ? String(localized: "\(share.name) reconnected") : String(localized: "\(share.name) mounted"),
                 body: path, category: Category.mounted)
        case .disconnected(let share, let reason):
            // User-initiated unmounts don't need a notification; only report losses.
            guard preferences.notifyOnDisconnect, reason != "Unmounted" else { return }
            post(share: share, title: String(localized: "\(share.name) disconnected"), body: reason, category: Category.lost)
        case .ejected:
            break
        case .authFailed(let share, let message):
            guard preferences.notifyOnAuthFailure else { return }
            post(share: share, title: String(localized: "Can’t sign in to \(share.name)"), body: message, category: Category.auth,
                 sound: true)
        case .stale(let share):
            guard preferences.notifyOnStale else { return }
            post(share: share, title: String(localized: "\(share.name) isn’t responding"),
                 body: String(localized: "Berth will remount it automatically when the server is back."), category: Category.lost)
        case .unreachable(let share, let message):
            guard preferences.notifyOnDisconnect else { return }
            post(share: share, title: String(localized: "Can’t reach \(share.name)"), body: message, category: Category.lost)
        }
    }

    private func post(share: Share, title: String, body: String, category: String, sound: Bool = false) {
        Task {
            if authorization == .notDetermined { await requestAuthorization() }
            guard authorization == .authorized || authorization == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.threadIdentifier = share.id.uuidString
            content.userInfo = ["shareID": share.id.uuidString]
            if sound { content.sound = .default }
            // One notification per share and kind: newer ones replace older ones.
            let request = UNNotificationRequest(identifier: "\(share.id.uuidString)-\(category)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["shareID"] as? String).flatMap(UUID.init(uuidString:))
        let actionID = response.actionIdentifier
        await MainActor.run {
            let action = Action(rawValue: actionID) ?? .open
            onAction?(action, id)
        }
    }
}
