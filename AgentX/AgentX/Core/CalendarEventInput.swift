import Foundation

// Kept independent of EventKit so time/schema validation can be exercised without writes.
struct CalendarEventInput {
    let title: String
    let start: Date
    let end: Date
    let zone: TimeZone
    let location: String?
    let alerts: AlertRequest?
    let features: CalendarFeatures?

    init(_ item: [String: Any], now: Date = Date(), productMode: Bool = false, testMode: Bool = true) throws {
        func invalid(_ text: String) -> NSError {
            NSError(domain: "AgentX.Validation", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        guard Set(item.keys).isSubset(of: Set(["item_id", "title", "start_at", "end_at", "time_zone"] + (productMode ? ["location", "alerts", "calendar"] : []))),
              let title = item["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (!testMode || title.hasPrefix("AgentX Test ")), title.count <= 160,
              let zoneName = item["time_zone"] as? String,
              TimeZone.knownTimeZoneIdentifiers.contains(zoneName), let zone = TimeZone(identifier: zoneName) else {
            throw invalid("Expected item_id/title/start_at/end_at/time_zone only; test title prefix and IANA time zone required")
        }
        func parse(_ value: Any?) throws -> Date {
            guard let s = value as? String,
                  s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
                throw invalid("Use ISO 8601 seconds with an explicit UTC offset, e.g. 2026-09-28T14:00:00+08:00")
            }
            let f = ISO8601DateFormatter()
            guard let date = f.date(from: s) else { throw invalid("Invalid ISO 8601 date") }
            // Reject normalized invalid dates and offsets inconsistent with the named zone.
            let roundtrip = DateFormatter()
            roundtrip.locale = Locale(identifier: "en_US_POSIX")
            roundtrip.calendar = Calendar(identifier: .gregorian)
            roundtrip.timeZone = zone
            roundtrip.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            guard roundtrip.string(from: date) == s else { throw invalid("Date or offset does not match time_zone") }
            return date
        }
        if let raw = item["calendar"] {
            features = try JSONDecoder().decode(CalendarFeatures.self, from: JSONSerialization.data(withJSONObject: raw))
            try features?.validate()
            guard features?.blocked != true else { throw invalid("日历功能或重复要求未解决，未创建") }
        } else { features = nil }
        let start = try parse(item["start_at"])
        let end = try parse(item["end_at"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard (productMode ? start > now : start >= calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!),
              end > start, end <= calendar.date(byAdding: .day, value: features == nil ? 1 : 366, to: start)! else {
            throw invalid("Event must start in the permitted future range, end after start and stay within the supported duration (legacy 1 day, v3 366 local days)")
        }
        if features?.is_all_day == true {
            guard calendar.startOfDay(for: start) == start, calendar.startOfDay(for: end) == end else {
                throw invalid("全天事件必须使用当地零点与排他结束日期")
            }
        }
        try features?.recurrence.validateAnchor(start: start, zone: zone)
        if let raw = item["alerts"] {
            alerts = try JSONDecoder().decode(AlertRequest.self, from: JSONSerialization.data(withJSONObject: raw))
            try alerts?.validate()
        } else { alerts = nil }
        self.location = item["location"] as? String
        self.title = title; self.start = start; self.end = end; self.zone = zone
    }
}
