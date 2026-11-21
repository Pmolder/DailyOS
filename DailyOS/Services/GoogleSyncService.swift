import Foundation

/// Direct REST client for Google Calendar API v3 (`calendar.readonly`)
/// and Google Tasks API v1 (`tasks.readonly`) without external SDKs.
enum GoogleSyncService {
    private static let calendarBase = "https://www.googleapis.com/calendar/v3"
    private static let tasksBase = "https://tasks.googleapis.com/tasks/v1"

    private static var isoFormatterWithFractional: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static var isoFormatterStandard: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFormatterWithFractional.date(from: raw) ?? isoFormatterStandard.date(from: raw)
    }

    // MARK: - Fetch Google Calendar Events (14-Day Horizon)

    static func fetchUpcomingCalendarEvents(
        accessToken: String,
        daysAhead: Int = 14
    ) async -> [FocusBlockDisplayItem] {
        let cal = ISOWeekCalendar.current
        let now = Date()
        let timeMinDate = cal.startOfDay(for: now)
        let timeMaxDate = cal.date(byAdding: .day, value: daysAhead, to: timeMinDate) ?? now.addingTimeInterval(Double(daysAhead) * 86400)

        let timeMin = isoFormatterStandard.string(from: timeMinDate)
        let timeMax = isoFormatterStandard.string(from: timeMaxDate)

        // 1. Fetch user's calendar list so secondary calendars (e.g., KOOL, Work, Study) are included
        let calendars = await fetchCalendarList(accessToken: accessToken)
        let targetCalendars = calendars.isEmpty
            ? [(id: "primary", summary: "Google Calendar")]
            : calendars

        var items: [FocusBlockDisplayItem] = []

        for entry in targetCalendars {
            guard let encodedID = entry.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                continue
            }
            var comps = URLComponents(string: "\(calendarBase)/calendars/\(encodedID)/events")
            comps?.queryItems = [
                URLQueryItem(name: "timeMin", value: timeMin),
                URLQueryItem(name: "timeMax", value: timeMax),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "100")
            ]
            guard let url = comps?.url else { continue }

            guard let json = await performAuthorizedGET(url: url, accessToken: accessToken),
                  let rawEvents = json["items"] as? [[String: Any]] else {
                continue
            }

            for ev in rawEvents {
                if (ev["status"] as? String) == "cancelled" { continue }
                guard let startDict = ev["start"] as? [String: Any],
                      let endDict = ev["end"] as? [String: Any],
                      let startDate = parseISODate(startDict["dateTime"] as? String),
                      let endDate = parseISODate(endDict["dateTime"] as? String),
                      endDate > startDate else {
                    // Skip all-day untimed calendar entries
                    continue
                }

                let eventID = (ev["id"] as? String) ?? UUID().uuidString
                let title = (ev["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let description = (ev["description"] as? String) ?? (ev["location"] as? String) ?? ""

                items.append(
                    FocusBlockDisplayItem(
                        id: "gcal_\(entry.id)_\(eventID)",
                        title: (title?.isEmpty == false ? title! : "Google Event"),
                        notes: description,
                        calendarTitle: entry.summary,
                        source: .googleCalendar,
                        startDate: startDate,
                        endDate: endDate,
                        manualBlockID: nil
                    )
                )
            }
        }

        return items.sorted { $0.startDate < $1.startDate }
    }

    private static func fetchCalendarList(accessToken: String) async -> [(id: String, summary: String)] {
        guard let url = URL(string: "\(calendarBase)/users/me/calendarList?minAccessRole=reader"),
              let json = await performAuthorizedGET(url: url, accessToken: accessToken),
              let items = json["items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let selected = (item["selected"] as? Bool) ?? true
            guard selected else { return nil }
            let summary = (item["summaryOverride"] as? String) ?? (item["summary"] as? String) ?? "Google Calendar"
            return (id: id, summary: summary)
        }
    }

    // MARK: - Fetch Google Tasks (Scheduled / Dated Tasks Days or Weeks Ahead)

    static func fetchScheduledGoogleTasks(
        accessToken: String,
        daysAhead: Int = 21
    ) async -> [FocusBlockDisplayItem] {
        guard let listsURL = URL(string: "\(tasksBase)/users/@me/lists"),
              let listsJSON = await performAuthorizedGET(url: listsURL, accessToken: accessToken),
              let taskLists = listsJSON["items"] as? [[String: Any]] else {
            return []
        }

        let cal = ISOWeekCalendar.current
        let todayStart = cal.startOfDay(for: Date())
        let horizonEnd = cal.date(byAdding: .day, value: daysAhead, to: todayStart) ?? todayStart.addingTimeInterval(Double(daysAhead) * 86400)

        var results: [FocusBlockDisplayItem] = []

        for list in taskLists {
            guard let listID = list["id"] as? String,
                  let encodedListID = listID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                continue
            }
            let listTitle = (list["title"] as? String) ?? "Google Tasks"

            var comps = URLComponents(string: "\(tasksBase)/lists/\(encodedListID)/tasks")
            comps?.queryItems = [
                URLQueryItem(name: "showCompleted", value: "false"),
                URLQueryItem(name: "showHidden", value: "false"),
                URLQueryItem(name: "maxResults", value: "100")
            ]
            guard let url = comps?.url,
                  let tasksJSON = await performAuthorizedGET(url: url, accessToken: accessToken),
                  let tasks = tasksJSON["items"] as? [[String: Any]] else {
                continue
            }

            for task in tasks {
                guard let taskID = task["id"] as? String,
                      let title = (task["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty,
                      let dueDateRaw = task["due"] as? String,
                      let parsedDueUTC = parseISODate(dueDateRaw) else {
                    continue
                }

                // Google Tasks API v1 returns due dates as RFC3339 midnight UTC (YYYY-MM-DDT00:00:00.000Z).
                // Map the calendar day into the user's local ISO-8601 timezone and parse optional "HH:mm-HH:mm" in notes.
                var utcCal = Calendar(identifier: .gregorian)
                utcCal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
                let utcComps = utcCal.dateComponents([.year, .month, .day], from: parsedDueUTC)

                let notes = (task["notes"] as? String) ?? ""
                let (startHour, startMin, durationMins) = parseOptionalTimeRange(from: notes) ?? (9, 0, 60)

                var localComps = DateComponents()
                localComps.year = utcComps.year
                localComps.month = utcComps.month
                localComps.day = utcComps.day
                localComps.hour = startHour
                localComps.minute = startMin
                localComps.second = 0

                guard let startDate = cal.date(from: localComps),
                      startDate >= todayStart,
                      startDate <= horizonEnd else {
                    continue
                }
                let endDate = startDate.addingTimeInterval(TimeInterval(durationMins * 60))

                results.append(
                    FocusBlockDisplayItem(
                        id: "gtask_\(listID)_\(taskID)",
                        title: title,
                        notes: notes,
                        calendarTitle: listTitle,
                        source: .googleTasks,
                        startDate: startDate,
                        endDate: endDate,
                        manualBlockID: nil
                    )
                )
            }
        }

        return results.sorted { $0.startDate < $1.startDate }
    }

    /// Parses optional time window from Google Task notes such as "14:00-17:00" or "14:00 - 15:30".
    private static func parseOptionalTimeRange(from notes: String) -> (Int, Int, Int)? {
        let pattern = #"(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              match.numberOfRanges == 5 else {
            return nil
        }

        func captureInt(_ idx: Int) -> Int? {
            guard let range = Range(match.range(at: idx), in: notes) else { return nil }
            return Int(notes[range])
        }

        guard let sh = captureInt(1), let sm = captureInt(2),
              let eh = captureInt(3), let em = captureInt(4),
              (0...23).contains(sh), (0...59).contains(sm),
              (0...23).contains(eh), (0...59).contains(em) else {
            return nil
        }

        let startTotal = sh * 60 + sm
        let endTotal = eh * 60 + em
        let duration = max(15, endTotal - startTotal)
        return (sh, sm, duration)
    }

    // MARK: - Authorized HTTP GET Helper

    private static func performAuthorizedGET(url: URL, accessToken: String) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
