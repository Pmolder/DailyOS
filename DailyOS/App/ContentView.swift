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
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsView()
        }
        // Locked full-screen Wake nuclear alarm cover (highest priority)
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
        // Live camera-only Focus AI Photo Proof modal (when Wake alarm is not actively ringing)
        .fullScreenCover(
            isPresented: Binding(
                get: { focusManager.isPhotoCaptureModalPresented && !alarmEngine.isAlarmRinging },
                set: { newValue in
                    if !newValue {
                        focusManager.cancelPhotoCaptureWithoutSubmitting()
                    }
                }
            )
        ) {
            FocusPhotoProofModalView()
        }
        .task {
            _ = await notificationScheduler.requestAuthorizationIfNeeded()
            alarmEngine.syncWithAlarms()
            focusManager.refreshTodaySchedule()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                alarmEngine.refreshGuidedAccessStatus()
                alarmEngine.syncWithAlarms()
                focusManager.refreshTodaySchedule()
            }
        }
        .onChange(of: focusManager.isCheckInDue) { _, isDue in
            if isDue && !alarmEngine.isAlarmRinging {
                selectedTab = 2
            }
        }
    }
}
