import SwiftUI
import SwiftData
import UserNotifications

@main
struct EnvelopeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    CloudSyncMonitor.shared.start(container: Persistence.shared)
                    SyncDeduplicator.runIfNeeded(in: Persistence.shared.mainContext)
                    await Notifier.requestAuthorization()
                    await ReminderScheduler.apply()
                }
        }
        .modelContainer(Persistence.shared)
        .onChange(of: scenePhase) { _, phase in
            // Merge iCloud duplicates while nothing is on screen.
            if phase == .background {
                SyncDeduplicator.runIfNeeded(in: Persistence.shared.mainContext)
            }
        }
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
