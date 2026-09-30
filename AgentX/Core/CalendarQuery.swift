import Foundation

struct CalendarQuery: Codable, Equatable {
    let mode: String // events, conflicts, free_slots
    let start_at: String
    let end_at: String
    let time_zone: String
    let duration_minutes: Int
    let day_start_minute: Int
    let day_end_minute: Int
    let assumptions: [String]
    var slot_kind: String? = nil
    var duration_days: Int? = nil
    var target_history_refs: [String]? = nil

    func bounds() throws -> (Date, Date, TimeZone) {
        func invalid() -> NSError { NSError(domain: "AgentX.Query", code: 1, userInfo: [NSLocalizedDescriptionKey: "查询参数无效：请选择最多一整年的明确时间范围、时区和 15–480 分钟时长。"] ) }
        guard ["events", "conflicts", "free_slots"].contains(mode),
              TimeZone.knownTimeZoneIdentifiers.contains(time_zone), let zone = TimeZone(identifier: time_zone),
              (15...480).contains(duration_minutes), (0...1439).contains(day_start_minute),
              (1...1440).contains(day_end_minute), day_start_minute < day_end_minute,
              assumptions.count <= 8, assumptions.allSatisfy({ !$0.isEmpty && $0.count <= 300 }) else { throw invalid() }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian); format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        func parse(_ text: String) throws -> Date {
            guard let date = ISO8601DateFormatter().date(from: text), format.string(from: date) == text.replacingOccurrences(of: "+00:00", with: "Z") else { throw invalid() }
            return date
        }
        guard [nil, "timed", "all_day"].contains(slot_kind), (1...366).contains(duration_days ?? 1),
              slot_kind != "all_day" || (day_start_minute == 0 && day_end_minute == 1440) else { throw invalid() }
        let start = try parse(start_at), end = try parse(end_at)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard end > start, end <= calendar.date(byAdding: .year, value: 1, to: start)! else { throw invalid() }
        return (start, end, zone)
    }
}

struct CalendarReadEvent: Codable {
    let title: String
    let start_at: String
    let end_at: String
    let is_all_day: Bool
    let calendar_name: String
    let blocks_time: Bool
    var occupancy_reason: String? = nil
}
struct CalendarFreeSlot: Codable, Equatable {
    let start_at: String
    let end_at: String
}
struct CalendarQueryResult: Codable {
    let request: CalendarQuery
    let queried_at: String
    let event_count: Int
    let busy_count: Int
    let events: [CalendarReadEvent]
    let events_truncated: Bool
    let free_slots: [CalendarFreeSlot]
    let slots_truncated: Bool
    let calendar_count: Int
    let scope_note: String
    // Deliberately excludes event titles, calendar names, notes and identifiers.
    var publicSummary: [String: Any] {
        ["operation": "calendar_query", "status": "query_complete", "queried_at": queried_at,
         "event_count": event_count, "busy_count": busy_count, "displayed_event_count": events.count,
         "slot_count": free_slots.count, "events_truncated": events_truncated, "slots_truncated": slots_truncated,
         "calendar_count": calendar_count, "execution_location": "iphone_native_app", "items": [],
         "privacy": "event_details_stay_on_phone"]
    }
}

// Half-open intervals: an event ending at 10:00 does not conflict with a 10:00 start.
enum CalendarAvailability {
    struct Span { let start: Date; let end: Date }
    static func overlaps(_ a: Span, _ b: Span) -> Bool { a.start < b.end && b.start < a.end }
    static func freeSlots(query: CalendarQuery, busy: [Span], now: Date = Date()) throws -> [CalendarFreeSlot] {
        let (start, end, zone) = try query.bounds()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        if query.slot_kind == "all_day" {
            var day = calendar.startOfDay(for: start), result: [CalendarFreeSlot] = []
            while day < end {
                let finish = calendar.date(byAdding: .day, value: query.duration_days ?? 1, to: day)!
                if day >= start && day > now && finish <= end && !busy.contains(where: { overlaps($0, Span(start: day, end: finish)) }) {
                    result.append(.init(start_at: AlertPolicy.format(day), end_at: AlertPolicy.format(finish)))
                }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            return result
        }
        var day = calendar.startOfDay(for: start), slots: [CalendarFreeSlot] = []
        while day < end {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            func wallTime(_ minute: Int) -> Date? {
                if minute == 1440 { return next }
                guard let date = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day, matchingPolicy: .strict),
                      calendar.isDate(date, inSameDayAs: day) else { return nil }
                return date
            }
            if let from = wallTime(query.day_start_minute), let to = wallTime(query.day_end_minute) {
                let lower = max(start, from, now), upper = min(end, to)
                if lower < upper {
                    let spans = busy.filter { overlaps($0, Span(start: lower, end: upper)) }.sorted { $0.start < $1.start }
                    var cursor = lower
                    func append(_ a: Date, _ b: Date) {
                        if b.timeIntervalSince(a) >= Double(query.duration_minutes * 60) {
                            slots.append(CalendarFreeSlot(start_at: AlertPolicy.format(a), end_at: AlertPolicy.format(b)))
                        }
                    }
                    for span in spans {
                        append(cursor, min(span.start, upper)); cursor = max(cursor, min(span.end, upper))
                    }
                    append(cursor, upper)
                }
            }
            day = next
        }
        return slots
    }
}

// Exact interval arithmetic, independent of model semantics. Bounded recurring
// checks disclose their horizon; never claim an infinite series is conflict-free.
enum CalendarOccurrences {
    struct Expansion { let spans: [CalendarAvailability.Span]; let complete: Bool; let horizon: Date }
    static func expand(start: Date, end: Date, zone: TimeZone, rule: RecurrenceRequest?, allDay: Bool) throws -> Expansion {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone; cal.firstWeekday = 2
        let horizon = cal.date(byAdding: .year, value: 1, to: start)!
        guard let rule, rule.mode == "repeat" else { return .init(spans: [.init(start: start, end: end)], complete: true, horizon: end) }
        try rule.validate(); try rule.validateAnchor(start: start, zone: zone)
        let firstDay = cal.startOfDay(for: start)
        let weekday = (cal.component(.weekday, from: start) + 5) % 7 + 1
        let monday = cal.date(byAdding: .day, value: 1 - weekday, to: firstDay)!
        let startClock = cal.dateComponents([.hour, .minute, .second], from: start)
        let endClock = cal.dateComponents([.hour, .minute, .second], from: end)
        let dayLength = cal.dateComponents([.day], from: firstDay, to: cal.startOfDay(for: end)).day!
        var day = firstDay, spans: [CalendarAvailability.Span] = []
        let until = rule.untilDate(zone: zone)
        while day < horizon {
            let dayIndex = cal.dateComponents([.day], from: firstDay, to: day).day!
            let weekIndex = cal.dateComponents([.day], from: monday, to: day).day! / 7
            let monthIndex = (cal.component(.year, from: day) - cal.component(.year, from: start)) * 12 + cal.component(.month, from: day) - cal.component(.month, from: start)
            let dom = cal.component(.day, from: day), iso = (cal.component(.weekday, from: day) + 5) % 7 + 1
            let matchesDay = rule.month_days.contains(dom) || (rule.month_days.contains(-1) && dom == cal.range(of: .day, in: .month, for: day)!.count)
            let matches: Bool
            switch rule.frequency {
            case "daily": matches = dayIndex % rule.interval == 0
            case "weekly": matches = weekIndex % rule.interval == 0 && rule.weekdays.contains(iso)
            case "monthly": matches = monthIndex % rule.interval == 0 && matchesDay
            case "yearly": matches = (cal.component(.year, from: day) - cal.component(.year, from: start)) % rule.interval == 0 && rule.months.contains(cal.component(.month, from: day)) && matchesDay
            default: throw CalendarFeatures.invalid("无法可靠展开重复规则")
            }
            func wall(_ day: Date, _ clock: DateComponents) -> Date? {
                guard let d = cal.date(bySettingHour: clock.hour!, minute: clock.minute!, second: clock.second!, of: day, matchingPolicy: .strict), cal.isDate(d, inSameDayAs: day), cal.component(.hour, from: d) == clock.hour else { return nil }; return d
            }
            if matches {
                guard let a = allDay ? day : wall(day, startClock) else { throw CalendarFeatures.invalid("重复发生遇到不存在的当地时间，无法确定系统展开边界，未放行") }
                if a < start || a >= horizon { day = cal.date(byAdding: .day, value: 1, to: day)!; continue }
                if let until, a > until { break }
                let endDay = cal.date(byAdding: .day, value: dayLength, to: day)!
                guard let b = allDay ? endDay : wall(endDay, endClock), b > a else { throw CalendarFeatures.invalid("重复发生的结束边界不明确，未声称检查成功") }
                spans.append(.init(start: a, end: b))
                if rule.end_type == "count", spans.count == rule.count { return .init(spans: spans, complete: true, horizon: b) }
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return .init(spans: spans, complete: until.map { $0 < horizon } ?? false, horizon: horizon)
    }
}
