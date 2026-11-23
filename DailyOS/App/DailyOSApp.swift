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
            FocusAccountabilityManager.shared.handleAppReopenCheck()
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
        } else if let type = userInfo["type"] as? String, type == PhotoProofScheduler.notificationType {
            Task { @MainActor in
                _ = PhotoProofScheduler.shared.handleNotificationInteraction(userInfo: userInfo)
                // Suppress duplicate banner when Floating PiP pill is actively morphing into the Photo-Proof alert
                if FocusPiPManager.shared.isPiPActive {
                    completionHandler([])
                } else {
                    completionHandler([.sound])
                }
            }
            return
        } else if let type = userInfo["type"] as? String, type == FocusNudgeScheduler.startNudgeType {
            Task { @MainActor in
                FocusNudgeScheduler.shared.handleDeliveredNudgeReplacement(userInfo: userInfo)
            }
            completionHandler([.banner, .list, .sound])
            return
        } else if let type = userInfo["type"] as? String, type == "focus_task_alarm" {
            let taskID = (userInfo["taskID"] as? String) ?? "active_focus_task"
            let taskTitle = (userInfo["taskTitle"] as? String) ?? "Scheduled Focus Task"
            let taskNotes = (userInfo["taskNotes"] as? String) ?? ""
            let taskSource = (userInfo["taskSource"] as? String) ?? "Focus"

            Task { @MainActor in
                if !FocusAccountabilityManager.shared.isFocusAlarmFullScreenPresented {
                    FocusAccountabilityManager.shared.activateFocusTaskAlarm(
                        taskID: taskID,
                        taskTitle: taskTitle,
                        taskNotes: taskNotes,
                        taskSource: taskSource,
                        evasionPenalty: FocusAccountabilityManager.shared.isEvasionPenaltyActive
                    )
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
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            if PhotoProofScheduler.shared.handleNotificationInteraction(userInfo: userInfo) {
                completionHandler()
                return
            }
            if FocusNudgeScheduler.shared.handleNotificationTap(userInfo: userInfo) {
                completionHandler()
                return
            }
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
                .environment(\.calendar, ISOWeekCalendar.current)
                .environment(\.locale, Locale(identifier: "en_GB"))
        }
    }
}
