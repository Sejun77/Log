import UIKit
import UserNotifications

/// Notification + haptic service
final class AppNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationService()

    // MARK: - Configure once at app launch
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
    }

    // MARK: - Request permission if not already granted
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus != .authorized else { return }

        do {
            _ = try await center.requestAuthorization(options: [
                .alert, .sound, .badge,
            ])
        } catch {
            print("🔕 Notification auth error:", error)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        let id = notification.request.identifier
        print("[Notification] willPresent: \(id)")
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Show it
        completionHandler([.banner, .sound, .list])

        // Auto-clear after a short delay if the user stays in the app
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        print(
            "[Notification] didReceive response for \(response.notification.request.identifier)"
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        completionHandler()
    }
}
