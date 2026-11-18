import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var alarmEngine = AlarmEngine.shared
    @ObservedObject private var notificationScheduler = NotificationScheduler.shared

    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            AlarmsListView()
                .tabItem {
                    Label("Alarms", systemImage: "alarm.fill")
                }
                .tag(0)

            HabitsListView()
                .tabItem {
                    Label("Habits", systemImage: "checklist.checked")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .tag(2)
        }
        .tint(.indigo)
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
        .task {
            _ = await notificationScheduler.requestAuthorizationIfNeeded()
            alarmEngine.syncWithAlarms()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                alarmEngine.syncWithAlarms()
            }
        }
    }
}
