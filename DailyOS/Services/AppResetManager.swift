import Foundation
import SwiftData
import UserNotifications
import WidgetKit
import UIKit

/// Performs a clean, atomic Factory Reset of all DailyOS persistence layers, notifications,
/// credentials, and App Group widget files.
@MainActor
enum AppResetManager {
    static func performFactoryReset(modelContext: ModelContext) {
        // 1. Stop any running audio, keep-alive, or focus alarms
        AlarmAudioManager.shared.stopPreview()
        AlarmAudioManager.shared.stopFocusWarning()
        AlarmAudioManager.shared.stopSilentKeepAlive(reEnableIdleTimer: true)

        // 2. Delete all SwiftData records across every registered @Model type
        try? modelContext.delete(model: HabitItem.self)
        try? modelContext.delete(model: HabitLog.self)
        try? modelContext.delete(model: AlarmItem.self)
        try? modelContext.delete(model: ManualFocusBlock.self)
        try? modelContext.delete(model: FocusCheckInLog.self)
        try? modelContext.save()
        SharedModelContainer.shared.save()

        // 3. Remove all pending & delivered notifications
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()

        // 4. Clear UserDefaults, Keychain credentials, Google OAuth, and App Group widget bridge files
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }

        GoogleAuthService.shared.signOut()
        KeychainService.saveGoogleClientID("")
        KeychainService.deleteGeminiAPIKey()
        WakeQRStorage.clear()
        WidgetBridge.clearAllBridgeFiles()

        // 5. Re-initialize clean state across managers & reload WidgetKit timelines
        FocusAccountabilityManager.shared.resetAfterFactoryReset()
        DailyNotificationManager.shared.resetToDefaults()
        AlarmEngine.shared.syncWithAlarms()
        WidgetSyncCoordinator.syncSnapshotFromStore()
        WidgetCenter.shared.reloadAllTimelines()

        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
