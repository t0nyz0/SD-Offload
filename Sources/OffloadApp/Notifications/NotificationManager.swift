import Foundation
import AppKit
import UserNotifications
import OffloadEngine

/// Bundle-guarded UNUserNotificationCenter wrapper.
/// CRITICAL: UNUserNotificationCenter.current() CRASHES in a bare `swift run`
/// binary (no bundle proxy) — every entry point checks `canNotify` first and
/// falls back to console logging in dev.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    static let canNotify: Bool = {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }()

    private var authRequested = false

    private func ensureAuth() {
        guard Self.canNotify, !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func install() {
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let eject = UNNotificationAction(identifier: "offload.eject", title: "Eject now")
        let complete = UNNotificationCategory(identifier: "offload.complete", actions: [eject],
                                              intentIdentifiers: [])
        let attention = UNNotificationCategory(identifier: "offload.attention", actions: [],
                                               intentIdentifiers: [])
        center.setNotificationCategories([complete, attention])
    }

    func notifySafeToRemove(cardName: String, sound: Bool) {
        post(title: "Card offloaded",
             body: "\(cardName) is verified on the NAS and safe to remove.",
             category: "offload.complete", sound: sound)
    }

    func notifyProblem(_ item: AttentionItem) {
        var body = item.detail
        if !item.cardWiped { body += " Your card has NOT been wiped." }
        post(title: item.title, body: body, category: "offload.attention", sound: true)
    }

    func notifyCardDetected(cardName: String) {
        post(title: "Card detected", body: "Offloading \(cardName)…", category: nil, sound: false)
    }

    private func post(title: String, body: String, category: String?, sound: Bool) {
        guard Self.canNotify else {
            print("[notification] \(title): \(body)")
            return
        }
        ensureAuth()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == "offload.eject" {
            await MainActor.run {
                NotificationCenter.default.post(name: .offloadEjectRequested, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let offloadEjectRequested = Notification.Name("offload.ejectRequested")
}
