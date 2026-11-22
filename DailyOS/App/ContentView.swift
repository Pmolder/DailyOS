import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared
    @ObservedObject private var focusManager = FocusAccountabilityManager.shared

    @State private var selectedTab: Int = 0
    @State private var showingSettingsSheet: Bool = false

    var body: some View {
        TabView(selection: $selectedTab) {
            AlarmsListView(onOpenSettings: { showingSettingsSheet = true })
                .tabItem {
                    Label("Wake", systemImage: "alarm.waves.left.and.right.fill")
                }
                .tag(0)

            HabitsListView(onOpenSettings: { showingSettingsSheet = true })
                .tabItem {
                    Label("Habits", systemImage: "square.grid.3x3.fill")
                }
                .tag(1)

            FocusTabView(onOpenSettings: { showingSettingsSheet = true })
                .tabItem {
                    Label("Focus", systemImage: "camera.viewfinder")
                }
                .tag(2)
        }
        .tint(.orange)
        .preferredColorScheme(.dark)
        .environment(\.calendar, ISOWeekCalendar.current)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
        }
        // Locked full-screen Wake Alarm cover (highest priority)
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
            SystemVolumeController.shared.ensureMountedInKeyWindow()
            _ = await notificationScheduler.requestAuthorizationIfNeeded()
            alarmEngine.syncWithAlarms()
            focusManager.handleAppReopenCheck()
            await focusManager.syncAllSources()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                SystemVolumeController.shared.ensureMountedInKeyWindow()
                alarmEngine.refreshGuidedAccessStatus()
                alarmEngine.syncWithAlarms()
                focusManager.handleAppReopenCheck()
                Task { await focusManager.syncAllSources() }
            }
        }
    }
}
