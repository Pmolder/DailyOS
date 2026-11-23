import Foundation

/// Seamless Two-Way Google Calendar REST client (`POST`, `PATCH`, `DELETE`) for mirroring
/// DailyOS `FocusTaskItem`s onto the user's `primary` Google Calendar with graceful 403 detection.
enum GoogleCalendarService {
    static let autoSyncStorageKey = "autoSyncFocusTasksToGoogleCalendar"
    private static let primaryEventsEndpoint = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

    static var isAutoSyncEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoSyncStorageKey) == nil {
                return true // Default ON
            }
            return UserDefaults.standard.bool(forKey: autoSyncStorageKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoSyncStorageKey)
        }
    }

    private static var isoFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }

    // MARK: - Create or Update Linked Google Calendar Event

    @MainActor
    static func pushTask(_ task: FocusTaskItem) async {
        let auth = GoogleAuthService.shared
        guard auth.isConnected, auth.syncGoogleCalendarEnabled, isAutoSyncEnabled, task.syncToGoogleCalendar else {
            return
        }
        guard let token = await auth.getValidAccessToken() else { return }

        let taskID = task.id
        let existingEventID = task.googleCalendarEventID
        let payload = buildEventPayload(for: task)

        if let eventID = existingEventID, !eventID.isEmpty {
            let status = await patchEvent(eventID: eventID, payload: payload, accessToken: token)
            if status == 403 {
                auth.needsWriteScopeReconnect = true
                return
            } else if status == 404 || status == 410 {
                // Event was deleted externally on Google Calendar; recreate cleanly
                if let newID = await postEvent(payload: payload, accessToken: token) {
                    applyReturnedEventID(newID, toTaskID: taskID)
                }
            } else if let s = status, (200...299).contains(s) {
                auth.needsWriteScopeReconnect = false
            }
        } else {
            let result = await postEventWithStatus(payload: payload, accessToken: token)
            if result.statusCode == 403 {
                auth.needsWriteScopeReconnect = true
                return
            }
            if let createdID = result.eventID {
                auth.needsWriteScopeReconnect = false
                applyReturnedEventID(createdID, toTaskID: taskID)
            }
        }

        // Refresh pulled remote blocks silently (duplicates filtered automatically by googleCalendarEventID)
        await FocusAccountabilityManager.shared.syncAllSources()
    }

    // MARK: - Delete Linked Google Calendar Event

    @MainActor
    static func deleteLinkedEvent(eventID: String?) async {
        guard let eventID = eventID?.trimmingCharacters(in: .whitespacesAndNewlines), !eventID.isEmpty else {
            return
        }
        let auth = GoogleAuthService.shared
        guard auth.isConnected, auth.syncGoogleCalendarEnabled, isAutoSyncEnabled else { return }
        guard let token = await auth.getValidAccessToken() else { return }

        guard let encoded = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(primaryEventsEndpoint)/\(encoded)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 403 {
                    auth.needsWriteScopeReconnect = true
                } else if (200...299).contains(http.statusCode) {
                    auth.needsWriteScopeReconnect = false
                }
            }
        } catch {
            print("[GoogleCalendarService] Delete event notice: \(error.localizedDescription)")
        }

        await FocusAccountabilityManager.shared.syncAllSources()
    }

    // MARK: - Payload Builder & REST Helpers

    @MainActor
    private static func applyReturnedEventID(_ eventID: String, toTaskID taskID: UUID) {
        let tasks = SharedModelContainer.shared.fetchFocusTasks()
        if let target = tasks.first(where: { $0.id == taskID }) {
            target.googleCalendarEventID = eventID
            SharedModelContainer.shared.save()
        }
    }

    @MainActor
    private static func buildEventPayload(for task: FocusTaskItem) -> [String: Any] {
        var dict: [String: Any] = [
            "summary": task.title
        ]

        let loc = task.trimmedLocation
        if !loc.isEmpty {
            dict["location"] = loc
        }

        let notes = task.trimmedNotes
        if !notes.isEmpty {
            dict["description"] = notes
        }

        if let start = task.startTime {
            let end = start.addingTimeInterval(TimeInterval(max(5, task.durationMinutes) * 60))
            let tzID = TimeZone.current.identifier
            dict["start"] = [
                "dateTime": isoFormatter.string(from: start),
                "timeZone": tzID
            ]
            dict["end"] = [
                "dateTime": isoFormatter.string(from: end),
                "timeZone": tzID
            ]
        } else {
            // Anytime task -> Google Calendar all-day event (exclusive end date = next day)
            let startKey = task.dayKey.isEmpty ? HabitItem.dateKey() : task.dayKey
            let startDate = HabitItem.date(from: startKey) ?? Date()
            let nextDay = ISOWeekCalendar.current.date(byAdding: .day, value: 1, to: startDate) ?? startDate.addingTimeInterval(86400)
            let endKey = HabitItem.dateKey(for: nextDay)
            dict["start"] = ["date": startKey]
            dict["end"] = ["date": endKey]
        }

        return dict
    }

    private static func postEvent(payload: [String: Any], accessToken: String) async -> String? {
        await postEventWithStatus(payload: payload, accessToken: accessToken).eventID
    }

    private static func postEventWithStatus(
        payload: [String: Any],
        accessToken: String
    ) async -> (statusCode: Int?, eventID: String?) {
        guard let url = URL(string: primaryEventsEndpoint),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return (nil, nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard let status, (200...299).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let createdID = json["id"] as? String else {
                return (status, nil)
            }
            return (status, createdID)
        } catch {
            return (nil, nil)
        }
    }

    private static func patchEvent(eventID: String, payload: [String: Any], accessToken: String) async -> Int? {
        guard let encoded = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(primaryEventsEndpoint)/\(encoded)"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }
}
