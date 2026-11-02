import SwiftUI
import SwiftData
import UserNotifications

@main
struct EnvelopeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DebugPaymentListView()
                .task { await Notifier.requestAuthorization() }
        }
        .modelContainer(Persistence.shared)
    }
}

/// Lets notifications show as banners while the app is in the foreground
/// (e.g. when tapping "Simulate payment").
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
