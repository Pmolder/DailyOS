import SwiftUI
import SwiftData
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    @State private var selectedTab: Int = 0

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = UIColor(red: 0.055, green: 0.055, blue: 0.075, alpha: 0.94)
        appearance.shadowColor = UIColor.white.withAlphaComponent(0.08)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HabitsListView()
                .tabItem {
                    Label("Habits", systemImage: "square.grid.3x3.fill")
                }
                .tag(0)

            AlarmsListView()
                .tabItem {
                    Label("Alarms", systemImage: "alarm.waves.left.and.right.fill")
                }
                .tag(1)

            FocusTabView(onOpenSettings: { selectedTab = 3 })
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
        .tint(DailyOSTheme.skyGlow)
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
        // Un-dismissible full-screen Focus Task Check-In Alarm / Evasion Penalty cover
        .fullScreenCover(
            isPresented: Binding(
                get: { focusManager.isFocusAlarmFullScreenPresented && !alarmEngine.isAlarmRinging },
                set: { _ in }
            )
        ) {
            FocusTaskAlarmFullScreenView()
        }
        .task {
            _ = await notificationScheduler.requestAuthorizationIfNeeded()
            alarmEngine.syncWithAlarms()
            focusManager.handleAppReopenCheck()
            await focusManager.syncAllSources()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                DispatchQueue.main.async {
                    SystemVolumeController.shared.ensureMountedInKeyWindow()
                }
                alarmEngine.refreshGuidedAccessStatus()
                alarmEngine.syncWithAlarms()
                focusManager.handleAppReopenCheck()
                Task { await focusManager.syncAllSources() }
            }
        }
    }
}
