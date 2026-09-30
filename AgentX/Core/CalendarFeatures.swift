import Foundation

// Version 3. One native recurrence rule, never a batch of synthetic occurrences.
struct RecurrenceRequest: Codable {
    let mode: String
    let frequency: String?
    let interval: Int
    let weekdays: [Int] // ISO Monday=1 ... Sunday=7
    let month_days: [Int]
    let months: [Int]
    let end_type: String
    let count: Int?
    let until: String? // inclusive local civil date
    let evidence: String?
    let reason: String

    func validate(text: String? = nil) throws {
        func bad() -> NSError { CalendarFeatures.invalid("重复规则非法或不完整，未降级为单次事件") }
        guard ["none", "repeat", "unresolved"].contains(mode), (1...99).contains(interval),
              !reason.isEmpty, reason.count <= 500 else { throw bad() }
        if let evidence { guard !evidence.isEmpty, text == nil || text!.contains(evidence) else { throw bad() } }
        if mode != "none" && evidence == nil { throw bad() }
        for (list, allowed) in [(weekdays, Set(1...7)), (month_days, Set(1...31).union([-1])), (months, Set(1...12))] {
            guard Set(list).count == list.count, Set(list).isSubset(of: allowed) else { throw bad() }
        }
        if mode != "repeat" {
            guard frequency == nil, interval == 1, weekdays.isEmpty, month_days.isEmpty, months.isEmpty,
                  end_type == "never", count == nil, until == nil else { throw bad() }
            return
        }
        if ["农历", "阴历", "调休", "法定"].contains(where: { evidence?.contains($0) == true }) {
            throw CalendarFeatures.invalid("当前只支持公历简单重复，不能将农历或调休降级为公历规则")
        }
        switch frequency {
        case "daily": guard weekdays.isEmpty, month_days.isEmpty, months.isEmpty else { throw bad() }
        case "weekly": guard !weekdays.isEmpty, month_days.isEmpty, months.isEmpty else { throw bad() }
        case "monthly": guard weekdays.isEmpty, !month_days.isEmpty, months.isEmpty else { throw bad() }
        case "yearly": guard weekdays.isEmpty, !month_days.isEmpty, !months.isEmpty, !month_days.contains(-1) else { throw bad() }
        default: throw bad()
        }
        switch end_type {
        case "never": guard count == nil, until == nil else { throw bad() }
        case "count": guard let count, (1...1000).contains(count), until == nil else { throw bad() }
        case "until": guard count == nil, let until, Self.civilDate(until, zone: TimeZone(secondsFromGMT: 0)!) != nil else { throw bad() }
        default: throw bad()
        }
    }
    static func civilDate(_ text: String, zone: TimeZone) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: text), f.string(from: date) == text else { return nil }
        return date
    }
    func untilDate(zone: TimeZone) -> Date? {
        guard let until, let day = Self.civilDate(until, zone: zone) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        return cal.date(byAdding: .day, value: 1, to: day)?.addingTimeInterval(-1)
    }
    func validateAnchor(start: Date, zone: TimeZone) throws {
        if mode != "repeat" { return }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let day = cal.component(.day, from: start)
        let matchesDay = month_days.contains(day) || (month_days.contains(-1) && day == cal.range(of: .day, in: .month, for: start)!.count)
        let weekday = (cal.component(.weekday, from: start) + 5) % 7 + 1
        guard (frequency != "weekly" || weekdays.contains(weekday)),
              (frequency != "monthly" && frequency != "yearly" || matchesDay),
              (frequency != "yearly" || months.contains(cal.component(.month, from: start))),
              (end_type != "until" || (untilDate(zone: zone).map { $0 >= start } ?? false)) else {
            throw CalendarFeatures.invalid("首次日期不符合重复规则，或重复结束日期早于首次；未创建")
        }
    }
    var summary: String {
        guard mode == "repeat" else { return mode == "none" ? "不重复" : "重复要求未解决：\(reason)" }
        let unit = ["daily":"天", "weekly":"周", "monthly":"月", "yearly":"年"][frequency ?? ""] ?? ""
        let names = [1:"一",2:"二",3:"三",4:"四",5:"五",6:"六",7:"日"]
        var label = "每\(interval == 1 ? "" : String(interval))\(unit)"
        if !weekdays.isEmpty { label += " · " + weekdays.sorted().map { "周" + names[$0]! }.joined(separator: "、") }
        if !months.isEmpty { label += " · " + months.sorted().map { "\($0)月" }.joined(separator: "、") }
        if !month_days.isEmpty { label += " · " + month_days.sorted().map { $0 == -1 ? "月末" : "\($0)日" }.joined(separator: "、") }
        label += end_type == "count" ? " · 共\(count ?? 0)次（含首次）" : end_type == "until" ? " · 截至\(until ?? "")（含当天）" : " · 不设结束日期"
        return label
    }
}

struct CalendarFeatures: Codable {
    let is_all_day: Bool
    let notes: String?
    let url: String?
    let recurrence: RecurrenceRequest
    let reason: String
    let unsupported: [String]
    var blocked: Bool { recurrence.mode == "unresolved" || !unsupported.isEmpty }
    static func invalid(_ message: String) -> NSError { NSError(domain: "AgentX.CalendarFeatures", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func validate(text: String? = nil) throws {
        try recurrence.validate(text: text)
        guard !reason.isEmpty, reason.count <= 500, unsupported.count <= 8,
              unsupported.allSatisfy({ !$0.isEmpty && $0.count <= 300 }),
              notes == nil || (!notes!.isEmpty && notes!.count <= 2000) else { throw Self.invalid("日历扩展字段非法") }
        if let url {
            guard url.count <= 2000, !url.contains(where: { $0.isWhitespace }),
                  let parsed = URLComponents(string: url), ["http", "https"].contains(parsed.scheme ?? ""),
                  !(parsed.host ?? "").isEmpty, parsed.user == nil, parsed.password == nil,
                  text == nil || text!.contains(url) else { throw Self.invalid("链接必须是原文提供的完整 http/https URL") }
        }
    }
    var wire: [String: Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:] }
}

#if canImport(EventKit)
import EventKit
extension RecurrenceRequest {
    func eventKitRule(zone: TimeZone) -> EKRecurrenceRule? {
        guard mode == "repeat" else { return nil }
        let frequencies: [String: EKRecurrenceFrequency] = ["daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly]
        let days = weekdays.sorted().map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0 % 7 + 1)!) }
        let end: EKRecurrenceEnd? = end_type == "count" ? EKRecurrenceEnd(occurrenceCount: count!) : (end_type == "until" ? EKRecurrenceEnd(end: untilDate(zone: zone)!) : nil)
        return EKRecurrenceRule(recurrenceWith: frequencies[frequency!]!, interval: interval,
            daysOfTheWeek: days.isEmpty ? nil : days, daysOfTheMonth: month_days.isEmpty ? nil : month_days.sorted().map { NSNumber(value: $0) },
            monthsOfTheYear: months.isEmpty ? nil : months.sorted().map { NSNumber(value: $0) },
            weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }
    static func snapshot(_ rules: [EKRecurrenceRule]?) -> [[String: Any]] {
        let frequencies: [EKRecurrenceFrequency: String] = [.daily: "daily", .weekly: "weekly", .monthly: "monthly", .yearly: "yearly"]
        return (rules ?? []).map { r -> [String: Any] in
            var row: [String: Any] = ["frequency": frequencies[r.frequency] ?? "unknown", "interval": r.interval]
            row["weekdays"] = (r.daysOfTheWeek ?? []).map { ["day": ($0.dayOfTheWeek.rawValue + 5) % 7 + 1, "week_number": $0.weekNumber] }
            row["month_days"] = (r.daysOfTheMonth ?? []).map(\.intValue)
            row["months"] = (r.monthsOfTheYear ?? []).map(\.intValue)
            row["weeks_of_year"] = (r.weeksOfTheYear ?? []).map(\.intValue)
            row["days_of_year"] = (r.daysOfTheYear ?? []).map(\.intValue)
            row["set_positions"] = (r.setPositions ?? []).map(\.intValue)
            row["first_day_of_week"] = r.firstDayOfTheWeek
            row["end_count"] = r.recurrenceEnd?.occurrenceCount as Any? ?? NSNull()
            row["end_at"] = r.recurrenceEnd?.endDate.map(AlertPolicy.format) as Any? ?? NSNull()
            return row
        }
    }

    func matches(_ rules: [EKRecurrenceRule]?, zone: TimeZone) -> Bool {
        guard mode == "repeat" else { return (rules ?? []).isEmpty }
        guard let rules, rules.count == 1, let expected = eventKitRule(zone: zone) else { return false }
        let actual = rules[0]
        guard actual.frequency == expected.frequency, actual.interval == interval,
              (actual.daysOfTheWeek ?? []).allSatisfy({ $0.weekNumber == 0 }),
              (actual.daysOfTheWeek ?? []).map({ ($0.dayOfTheWeek.rawValue + 5) % 7 + 1 }).sorted() == weekdays.sorted(),
              (actual.daysOfTheMonth ?? []).map(\.intValue).sorted() == month_days.sorted(),
              (actual.monthsOfTheYear ?? []).map(\.intValue).sorted() == months.sorted(),
              (actual.weeksOfTheYear ?? []).isEmpty, (actual.daysOfTheYear ?? []).isEmpty, (actual.setPositions ?? []).isEmpty,
              actual.firstDayOfTheWeek == expected.firstDayOfTheWeek else { return false }
        switch end_type {
        case "count": return actual.recurrenceEnd?.occurrenceCount == count && actual.recurrenceEnd?.endDate == nil
        case "until": return actual.recurrenceEnd?.occurrenceCount == 0 && actual.recurrenceEnd?.endDate.map { abs($0.timeIntervalSince(untilDate(zone: zone)!)) < 1 } == true
        default: return actual.recurrenceEnd == nil
        }
    }
}
#endif
