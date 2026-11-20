import SwiftUI
import SwiftData
import UserNotifications
import AppIntents

final class DailyOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        WavFileSynthesizer.ensureCustomSoundsInstalled()
        UNUserNotificationCenter.current().delegate = self

        Task { @MainActor in
            NotificationScheduler.shared.registerNotificationCategories()
            AlarmEngine.shared.syncWithAlarms()
            FocusAccountabilityManager.shared.refreshTodaySchedule()
            DailyOSShortcutsProvider.updateAppShortcutParameters()
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if let alarmIDString = userInfo["alarmID"] as? String,
           let alarmUUID = UUID(uuidString: alarmIDString) {
            Task { @MainActor in
                let alarms = SharedModelContainer.shared.fetchAlarms()
                if let alarm = alarms.first(where: { $0.id == alarmUUID }),
                   AlarmEngine.shared.activeRingingAlarm == nil {
                    AlarmEngine.shared.triggerAlarm(alarm)
                }
            }
        } else if let type = userInfo["type"] as? String, type == "focus_checkin" {
            Task { @MainActor in
                if !FocusAccountabilityManager.shared.isCheckInDue {
                    FocusAccountabilityManager.shared.triggerCheckInDue(immediateAlarm: false)
                }
            }
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            await NotificationScheduler.shared.handleNotificationResponse(response)
            completionHandler()
        }
    }
}

@main
struct DailyOSApp: App {
    @UIApplicationDelegateAdaptor(DailyOSAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(SharedModelContainer.shared.container)
                .preferredColorScheme(.dark)
        }
    }
}
