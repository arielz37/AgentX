import EventKit
import Foundation

// Keep a fixed pair of long-lived connections for the whole native host. Writes
// and independent readback never share EKEvent objects. Reset only at synchronous
// operation boundaries, before fetching any objects; callers must return values,
// not retain EventKit objects across another operation or an await.
@MainActor final class CalendarEventStores {
    static let shared = CalendarEventStores()
    let writer = EKEventStore()
    private let reader = EKEventStore()
    func freshWriter() -> EKEventStore { writer.reset(); return writer }
    func freshReader() -> EKEventStore { reader.reset(); return reader }
}

struct CalendarScopeOption: Identifiable {
    let id: String
    let title: String
    let included: Bool
    let reason: String
}

// Display and occupancy are separate. Never infer occupancy from an event title.
// Holiday-name recognition is deliberately limited to read-only subscriptions;
// unfamiliar calendars remain included, with a local user override for either case.
enum CalendarOccupancyPolicy {
    static let preferenceKey = "AgentX.calendarOccupancyOverrides.v1"
    static func option(_ calendar: EKCalendar, preferences: UserDefaults) -> CalendarScopeOption {
        let name = calendar.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let holidayName = name.hasSuffix("节假日") || name.hasSuffix("節假日") || name.hasSuffix("節日") || name.hasSuffix("节日")
            || name.hasSuffix(" holidays") || name == "holidays" || name.hasPrefix("holidays in ")
        let holiday = (calendar.isSubscribed || calendar.type == .subscription) && !calendar.allowsContentModifications && holidayName
        let overrides = preferences.dictionary(forKey: preferenceKey) ?? [:]
        let override = overrides[calendar.calendarIdentifier] as? Bool
        let included = override ?? !holiday
        let reason: String
        if let override { reason = override ? "你已设置此日历参与忙闲计算。" : "你已设置此日历仅展示，不参与忙闲计算。" }
        else if holiday { reason = "识别为只读节假日订阅，仅展示日期信息，不代表个人时间被占用；可在设置中更改。" }
        else { reason = "默认参与忙闲计算；全天安排也可能占时，可在设置中更改。" }
        return CalendarScopeOption(id: calendar.calendarIdentifier, title: calendar.title, included: included, reason: reason)
    }
    static func set(_ id: String, included: Bool, preferences: UserDefaults) {
        var overrides = preferences.dictionary(forKey: preferenceKey) ?? [:]
        overrides[id] = included; preferences.set(overrides, forKey: preferenceKey)
    }
}

// Only called for an explicit task or a new v4 event's conflict check; never on launch.
@MainActor
final class CalendarReader {
    private let preferences: UserDefaults
    private let stores: CalendarEventStores
    init(preferences: UserDefaults = .standard, stores: CalendarEventStores? = nil) {
        self.preferences = preferences; self.stores = stores ?? .shared
    }
    func calendarOptions() -> [CalendarScopeOption] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return stores.freshReader().calendars(for: .event).map { CalendarOccupancyPolicy.option($0, preferences: preferences) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func fail(_ text: String) -> NSError { NSError(domain: "AgentX.CalendarRead", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func query(_ request: CalendarQuery, detailLimit: Int = 100, slotLimit: Int = 20, excluding: ((EKEvent) -> Bool)? = nil, now: Date = Date()) throws -> CalendarQueryResult {
        let (start, end, _) = try request.bounds()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw fail("日历读取需要完全访问权限，请先在设置中准备；本次没有弹出授权界面。") }
        let store = stores.freshReader()
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { throw fail("calendar_read_unavailable: 日历接口本次未返回可读取日历，无法判断空闲；这不代表没有安排，本次不写入。") }
        // Use Apple's occurrence-range predicate, not event(withIdentifier:) for a series.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let raw = store.events(matching: predicate)
        guard raw.count <= 2000 else { throw fail("范围内事件过多，请缩短查询日期；未生成可能遗漏占用的空闲建议。") }
        var spans: [CalendarAvailability.Span] = [], rows: [CalendarReadEvent] = []
        for event in raw {
            guard event.status != .canceled, excluding?(event) != true else { continue }
            guard let a = event.startDate, let b = event.endDate, b >= a else { throw fail("日历中存在无效起止时间，无法完整判断占用。") }
            // Include zero-duration entries in the agenda, but they don't occupy a slot.
            guard a == b ? (a >= start && a < end) : (a < end && b > start) else { continue }
            let scope = event.calendar.map { CalendarOccupancyPolicy.option($0, preferences: preferences) }
            let busy = (scope?.included ?? true) && event.availability != .free && b > a
            let reason: String
            if let scope, !scope.included { reason = scope.reason }
            else if b == a { reason = "零时长事项，不占用区间。" }
            else if event.availability == .free { reason = "事件标记为空闲，不占用区间。" }
            else if event.availability == .notSupported { reason = "所属日历没有提供忙闲状态，当前保守计为占用；这不代表已经确认你有预约。" }
            else { reason = event.isAllDay ? "全天事件被计为占用，覆盖与查询重叠的整段时间。" : "事件未标记为空闲，计为占用。" }
            if busy { spans.append(.init(start: a, end: b)) }
            rows.append(CalendarReadEvent(title: String((event.title ?? "无标题事项").prefix(200)), start_at: AlertPolicy.format(a), end_at: AlertPolicy.format(b),
                is_all_day: event.isAllDay, calendar_name: String((event.calendar?.title ?? "日历").prefix(100)), blocks_time: busy, occupancy_reason: reason))
        }
        rows.sort { $0.start_at == $1.start_at ? $0.end_at < $1.end_at : $0.start_at < $1.start_at }
        let free = request.mode == "free_slots" ? try CalendarAvailability.freeSlots(query: request, busy: spans, now: now) : []
        return CalendarQueryResult(request: request, queried_at: AlertPolicy.format(now), event_count: rows.count, busy_count: spans.count,
            events: Array(rows.prefix(detailLimit)), events_truncated: rows.count > detailLimit,
            free_slots: Array(free.prefix(slotLimit)), slots_truncated: free.count > slotLimit, calendar_count: calendars.count,
            scope_note: "展示手机可访问的日历；忙闲仅按设置中参与计算的日历判断，包含测试事件。识别出的只读节假日订阅默认只展示。已取消和标记为空闲的事件不占时，参与计算但未提供忙闲状态的事件仍保守计入。结果是查询时快照，不代表未同步的安排，也未预留这些时段。")
    }

    // Coverage is explicitly the requested occurrence, never the entire repeat series.
    func conflicts(start: Date, end: Date, zone: TimeZone, recurring: Bool, excluding: ((EKEvent) -> Bool)? = nil, now: Date = Date()) throws -> [String: Any] {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone; format.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        let duration = end.timeIntervalSince(start)
        let request = CalendarQuery(mode: "conflicts", start_at: format.string(from: start), end_at: format.string(from: end), time_zone: zone.identifier,
            duration_minutes: 60, day_start_minute: 0, day_end_minute: 1440, assumptions: [])
        let result = try query(request, excluding: excluding, now: now)
        var output: [String: Any] = ["status": result.busy_count == 0 ? "clear" : "conflict", "checked_at": result.queried_at,
            "busy_count": result.busy_count, "coverage": recurring ? "first_occurrence_only" : "requested_interval",
            "scope_note": result.scope_note, "suggestions": [], "suggestion_note": ""]
        // Suggestions are informational only. Never move a requested time or create from them.
        if result.busy_count > 0 && duration >= 900 && duration <= 8 * 3600 {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let lower = calendar.startOfDay(for: max(start, now)), upper = calendar.date(byAdding: .day, value: 7, to: lower)!
            let proposal = CalendarQuery(mode: "free_slots", start_at: format.string(from: lower), end_at: format.string(from: upper), time_zone: zone.identifier,
                duration_minutes: Int(ceil(duration / 60)), day_start_minute: 9 * 60, day_end_minute: 21 * 60,
                assumptions: ["建议搜索范围为目标日期起 7 天，每天 09:00–21:00；未自动修改日程。"])
            do {
                let suggestions = try query(proposal, now: now)
                output["suggestions"] = suggestions.free_slots.prefix(3).map { ["start_at": $0.start_at, "end_at": $0.end_at] }
                output["suggestion_note"] = proposal.assumptions[0]
            } catch { output["suggestion_note"] = "冲突已确认，但空闲建议查询失败；没有自动改期。" }
        }
        return output
    }
}

extension CalendarReader {
    func comprehensiveConflicts(_ input: CalendarEventInput) throws -> [String: Any] {
        let expansion = try CalendarOccurrences.expand(start: input.start, end: input.end, zone: input.zone, rule: input.features?.recurrence, allDay: input.features?.is_all_day == true)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, let first = expansion.spans.first, let last = expansion.spans.last else { throw CalendarFeatures.invalid("权限不足或无法展开待检查区间") }
        let store = stores.freshReader()
        guard !store.calendars(for: .event).isEmpty else { throw CalendarFeatures.invalid("calendar_read_unavailable: 日历接口本次未返回可读取日历，无法检查冲突，本项未保存") }
        let events = store.events(matching: store.predicateForEvents(withStart: first.start, end: last.end, calendars: nil))
        guard events.count <= 10000 else { throw CalendarFeatures.invalid("冲突范围事件过多，未以不完整结果放行") }
        var overlaps: [[String: Any]] = [], count = 0
        for (index, span) in expansion.spans.enumerated() {
            for previous in expansion.spans.prefix(index) where CalendarAvailability.overlaps(previous, span) {
                count += 1
                if overlaps.count < 20 { overlaps.append(["kind": "series_self_overlap", "requested_start": AlertPolicy.format(span.start), "busy_start": AlertPolicy.format(previous.start)]) }
            }
        }
        for span in expansion.spans {
            for event in events where event.status != .canceled && event.availability != .free {
                guard let a = event.startDate, let b = event.endDate, b >= a else { throw CalendarFeatures.invalid("已有事项边界无效") }
                if let calendar = event.calendar, !CalendarOccupancyPolicy.option(calendar, preferences: preferences).included { continue }
                if b > a && CalendarAvailability.overlaps(span, .init(start: a, end: b)) {
                    count += 1
                    if overlaps.count < 20 { overlaps.append(["requested_start": AlertPolicy.format(span.start), "requested_end": AlertPolicy.format(span.end), "busy_start": AlertPolicy.format(a), "busy_end": AlertPolicy.format(b)]) }
                }
            }
        }
        return ["status": count == 0 ? "clear" : "conflict", "checked_at": AlertPolicy.format(Date()), "busy_count": count,
                "coverage": input.features?.recurrence.mode != "repeat" ? "requested_interval" : (expansion.complete ? "full_series" : "one_year_horizon"),
                "occurrences_checked": expansion.spans.count, "checked_until": AlertPolicy.format(expansion.horizon), "series_complete": expansion.complete,
                "overlaps": overlaps, "overlaps_truncated": count > overlaps.count, "suggestions": [], "suggestion_note": "",
                "scope_note": expansion.complete ? "检查全部请求发生区间，写入前快照不构成跨应用锁。" : "仅检查首次起一年内的重复发生；之后未检查，不代表整个系列无冲突。"]
    }
}
