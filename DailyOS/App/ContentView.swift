import SwiftUI
import SwiftData
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared
    @ObservedObject private var photoProofScheduler = PhotoProofScheduler.shared

    @State private var selectedTab: Int = 0
    @State private var lastActiveDayKey: String = HabitItem.dateKey()
    @State private var dayRolloverToken: UUID = UUID()

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = UIColor(red: 0.055, green: 0.055, blue: 0.075, alpha: 0.95)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.075)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HabitsListView()
                .id("habits_\(dayRolloverToken.uuidString)")
                .tabItem {
                    Label("Habits", systemImage: "square.grid.3x3.fill")
                }
                .tag(0)

            AlarmsListView()
                .tabItem {
                    Label("Alarms", systemImage: "alarm.waves.left.and.right.fill")
                }
                .tag(1)

            FocusTabView()
                .id("focus_\(dayRolloverToken.uuidString)")
                .tabItem {
                    Label("Focus", systemImage: "timer")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .tint(DailyOSTheme.indigoGlow)
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
        // Locked full-screen Wake Alarm cover (highest priority — Solar-Orange theme)
        .fullScreenCover(
            item: Binding(
                get: { alarmEngine.activeRingingAlarm },
                set: { _ in }
            )
        ) { ringingAlarm in
            AlarmRingingView(alarm: ringingAlarm) {
                alarmEngine.dismissActiveAlarm()
            }
        }
        // Smart Focus Photo Proof & Random Spot-Check Live Camera Capture Sheet
        .fullScreenCover(
            item: Binding(
                get: { alarmEngine.isAlarmRinging ? nil : photoProofScheduler.activeCaptureRequest },
                set: { if $0 == nil { photoProofScheduler.activeCaptureRequest = nil } }
            )
        ) { proofRequest in
            PhotoProofCaptureSheet(request: proofRequest)
        }
        // Un-dismissible full-screen Focus Task Check-In Alarm / Evasion Penalty cover
        .fullScreenCover(
            isPresented: Binding(
                get: {
                    focusManager.isFocusAlarmFullScreenPresented
                    && !alarmEngine.isAlarmRinging
                    && photoProofScheduler.activeCaptureRequest == nil
                },
                set: { _ in }
            )
        ) {
            FocusTaskAlarmFullScreenView()
        }
        .task {
            _ = await notificationScheduler.requestAuthorizationIfNeeded()
            handleMidnightRolloverIfNeeded()
            WidgetSyncCoordinator.consumePendingDeltasAndSync()
            alarmEngine.syncWithAlarms()
            focusManager.handleAppReopenCheck()
            await focusManager.syncAllSources()
            await DailyNotificationManager.shared.refreshScheduledNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            handleMidnightRolloverIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                DispatchQueue.main.async {
                    SystemVolumeController.shared.ensureMountedInKeyWindow()
                }
                handleMidnightRolloverIfNeeded()
                WidgetSyncCoordinator.consumePendingDeltasAndSync()
                alarmEngine.refreshGuidedAccessStatus()
                alarmEngine.syncWithAlarms()
                focusManager.handleAppReopenCheck()
                Task {
                    await focusManager.syncAllSources()
                    await DailyNotificationManager.shared.refreshScheduledNotifications()
                }
            } else if newPhase == .background || newPhase == .inactive {
                WidgetSyncCoordinator.syncSnapshotFromStore()
                Task {
                    await DailyNotificationManager.shared.refreshScheduledNotifications()
                }
            }
        }
    }

    /// Detects midnight (00:00 local time) rollover cleanly, refreshing dayKeys, daily checklists,
    /// habit states, Today's Score, Evening Momentum notifications, and Home Screen widgets.
    private func handleMidnightRolloverIfNeeded() {
        let currentKey = HabitItem.dateKey(for: Date())
        guard currentKey != lastActiveDayKey else { return }
        lastActiveDayKey = currentKey
        dayRolloverToken = UUID()
        WidgetSyncCoordinator.syncSnapshotFromStore()
        Task {
            await DailyNotificationManager.shared.refreshScheduledNotifications()
        }
    }
}
