import EventKit
import Foundation
import CryptoKit

@MainActor final class CalendarMutator {
    private let ledgerURL: URL
    private var rows: [String: Data] = [:]
    private var healthy = true
    private let stores: CalendarEventStores
    var mayWrite: (() -> Bool)?
    init(ledgerURL: URL, stores: CalendarEventStores? = nil) {
        self.ledgerURL = ledgerURL; self.stores = stores ?? .shared
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            do { rows = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: ledgerURL)) }
            catch { healthy = false }
        }
    }
    private func fail(_ text: String) -> NSError { NSError(domain: "AgentX.Mutation", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func stamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    private func parse(_ s: String) throws -> Date { guard let d = ISO8601DateFormatter().date(from: s) else { throw fail("日期格式无效") }; return d }
    private func local(_ d: Date, zone: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"; return f.string(from: d)
    }
    private func snapshot(_ event: EKEvent) -> [String: Any] {
        ["title": event.title ?? "", "start_at": stamp(event.startDate), "end_at": stamp(event.endDate),
         "time_zone": event.timeZone?.identifier ?? "", "is_all_day": event.isAllDay,
         "location": event.location ?? "", "notes": event.notes ?? "", "url": event.url?.absoluteString ?? "",
         "calendar_id": event.calendar?.calendarIdentifier ?? "", "recurrence": RecurrenceRequest.snapshot(event.recurrenceRules),
         "attendees": event.attendees?.count ?? 0, "status": event.status.rawValue, "availability": event.availability.rawValue,
         "last_modified_at": event.lastModifiedDate.map(stamp) ?? "",
         "alarms": (event.alarms ?? []).map { ["offset": $0.relativeOffset, "at": $0.absoluteDate.map(stamp) ?? "", "location": $0.structuredLocation != nil, "proximity": $0.proximity.rawValue] as [String: Any] }]
    }
    private func fingerprint(_ event: EKEvent) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: snapshot(event), options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
    }
    func read(_ query: CalendarQuery, history: [ConversationLookup] = []) throws -> MutationSnapshot {
        let (start, end, zone) = try query.bounds()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw fail("修改/删除前需要完全日历访问，执行中不弹出授权") }
        let store = stores.freshReader(), calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { throw fail("calendar_read_unavailable: 日历接口本次未返回可读取日历，不能据此判断目标已删除") }
        var events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).filter { $0.status != .canceled }.sorted { $0.startDate < $1.startDate }
        // Reconcile recent nonrecurring writes by identity, so a user's manual
        // rename/move need not remain in the stale historical date range.
        var links: [String: [String]] = [:]
        for link in history.prefix(120) {
            guard let current = store.event(withIdentifier: link.event_id), current.status != .canceled,
                  (current.recurrenceRules ?? []).isEmpty, let id = current.eventIdentifier else { continue }
            links[id, default: []].append(link.history_ref)
            if !events.contains(where: { $0.eventIdentifier == id && $0.startDate == current.startDate }) { events.append(current) }
        }
        events.sort { $0.startDate < $1.startDate }
        guard events.count <= 2000 else { throw fail("候选超过2000条，请缩小日期范围；未截断后选取目标") }
        let candidates = try events.compactMap { event -> MutationCandidate? in
            guard let id = event.eventIdentifier, event.startDate != nil, event.endDate != nil else { return nil }
            return MutationCandidate(target_ref: UUID().uuidString, event_id: id, fingerprint: try fingerprint(event), title: event.title ?? "", start_at: local(event.startDate, zone: zone), end_at: local(event.isAllDay ? (AllDayDates.exclusiveEnd(start: event.startDate, end: event.endDate, zone: zone) ?? event.endDate) : event.endDate, zone: zone), time_zone: event.timeZone?.identifier ?? zone.identifier, is_all_day: event.isAllDay, calendar_name: event.calendar?.title ?? "", writable: event.calendar?.allowsContentModifications == true && (event.attendees ?? []).isEmpty, recurring: !(event.recurrenceRules ?? []).isEmpty, location: event.location, notes: event.notes, url: event.url?.absoluteString, related_history_refs: links[id] ?? [])
        }
        return .init(source_id: UUID().uuidString, queried_at: stamp(Date()), query: query, candidates: candidates)
    }
    private func find(_ target: MutationCandidate, store: EKEventStore) throws -> EKEvent? {
        let a = try parse(target.start_at), b = try parse(target.end_at)
        let matches = store.events(matching: store.predicateForEvents(withStart: a.addingTimeInterval(-1), end: max(a.addingTimeInterval(1), b), calendars: nil)).filter { $0.eventIdentifier == target.event_id && abs($0.startDate.timeIntervalSince(a)) < 1 }
        guard matches.count <= 1 else { throw fail("事件标识不唯一，请重新查询") }
        return matches.first
    }
    private func persist(_ key: String, _ payload: Data, _ result: [String: Any]) throws {
        rows[key] = try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "result": result], options: [.sortedKeys])
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try JSONEncoder().encode(rows).write(to: ledgerURL, options: .atomic) } catch { healthy = false; throw error }
    }
    func execute(taskID: String, decision: MutationDecision, source: MutationSnapshot, testMode: Bool) throws -> [String: Any] {
        try decision.validate(snapshot: source)
        guard decision.decision == "execute" else { throw fail("尚未形成可执行的修改/删除决定") }
        let results = decision.actions.map { executeItem(taskID: taskID, action: $0, source: source, testMode: testMode) }
        let done = results.filter { $0["status"] as? String == "verified" }.count
        let status = done == results.count ? "verified" : (done > 0 ? "partial" : (results.contains { $0["status"] as? String == "unknown" } ? "unknown" : (results.contains { $0["save_status"] as? String == "saved" } ? "saved_unverified" : "not_completed")))
        return ["operation": "calendar_mutation", "status": status, "execution_location": "iphone_native_app", "items": results, "completed_at": stamp(Date())]
    }
    private func executeItem(taskID: String, action: MutationAction, source: MutationSnapshot, testMode: Bool) -> [String: Any] {
        let target = source.candidates.first { $0.target_ref == action.target_ref }!
        let key = taskID + "/" + action.item_id
        var payload = Data()
        var result: [String: Any] = ["item_id": action.item_id, "operation": action.operation, "scope": action.scope, "title": target.title, "received_at": stamp(Date()), "status": "failed", "save_status": "not_attempted", "verification_status": "not_attempted"]
        var attempted = false
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            payload = try encoder.encode(action)
            if let row = rows[key], let old = try JSONSerialization.jsonObject(with: row) as? [String: Any] {
                guard old["payload"] as? String == payload.base64EncodedString(), var report = old["result"] as? [String: Any] else { throw fail("相同任务已有不同修改/删除，拒绝覆盖") }
                report["deduplicated"] = true; return report
            }
            guard healthy, mayWrite?() == true, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw fail("存储、权限或执行窗口不可用") }
            let store = stores.freshWriter()
            guard let event = try find(target, store: store), try fingerprint(event) == target.fingerprint else { throw fail("事件已变化或消失，请重新查询后再决定，未覆盖外部改动") }
            guard event.calendar?.allowsContentModifications == true, (event.attendees ?? []).isEmpty else { throw fail("只读日历或带邀请人的事项不允许本工具更改") }
            guard !testMode || (event.title ?? "").hasPrefix("AgentX Test ") else { throw fail("测试模式仅可修改/删除 AgentX Test 前缀事项") }
            result["before"] = snapshot(event)
            let span: EKSpan = action.scope == "future_events" ? .futureEvents : .thisEvent
            if action.operation == "update", let patch = action.patch {
                if let title = patch.title {
                    let decorated = testMode && !title.hasPrefix("AgentX Test ") ? "AgentX Test " + title : title
                    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, decorated.count <= 160 else { throw fail("标题无效") }; event.title = decorated
                }
                let zone = try patch.time_zone.map { name -> TimeZone in guard let z = TimeZone(identifier: name) else { throw fail("时区无效") }; return z } ?? event.timeZone ?? TimeZone(identifier: source.query.time_zone)!
                let changedTime = patch.start_at != nil || patch.end_at != nil || patch.is_all_day != nil || patch.time_zone != nil
                if target.recurring && action.scope == "future_events" && changedTime { throw fail("重复系列整体改时需要逐次重排，本版请指定单次发生；未只检查首次就修改整个系列") }
                if let a = patch.start_at { let d = try parse(a); guard local(d, zone: zone) == a else { throw fail("开始时间与时区不一致") }; event.startDate = d }
                if let b = patch.end_at { let d = try parse(b); guard local(d, zone: zone) == b else { throw fail("结束时间与时区不一致") }; event.endDate = d }
                if patch.time_zone != nil { event.timeZone = zone }
                if let allDay = patch.is_all_day { event.isAllDay = allDay }
                guard event.endDate > event.startDate else { throw fail("结束时间必须晚于开始") }
                if changedTime { guard event.startDate > Date() else { throw fail("改期目标已经过去") } }
                var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
                if event.isAllDay && changedTime { guard cal.startOfDay(for: event.startDate) == event.startDate, cal.startOfDay(for: event.endDate) == event.endDate else { throw fail("全天需当地零点及排他结束日") } }
                if let x = patch.location { event.location = x.isEmpty ? nil : x }
                if let x = patch.notes { guard x.count <= 2000 else { throw fail("备注过长") }; event.notes = x.isEmpty ? nil : x }
                if let x = patch.url { guard x.isEmpty || (["http", "https"].contains(URLComponents(string: x)?.scheme ?? "") && URLComponents(string: x)?.host != nil && URLComponents(string: x)?.user == nil && URLComponents(string: x)?.password == nil) else { throw fail("链接无效") }; event.url = x.isEmpty ? nil : URL(string: x) }
                if let offsets = patch.reminder_offsets_seconds {
                    guard offsets.count <= 2, Set(offsets).count == offsets.count, offsets.allSatisfy({ $0 <= 0 && $0 >= -31 * 86400 && event.startDate.addingTimeInterval(Double($0)) > Date().addingTimeInterval(300) }) else { throw fail("提醒参数无效或已过期，未静默替换") }
                    event.alarms = offsets.map { EKAlarm(relativeOffset: Double($0)) }
                }
                if changedTime {
                    let originalStart = try parse(target.start_at)
                    let check = try CalendarReader(stores: stores).conflicts(start: event.startDate, end: event.endDate, zone: zone, recurring: false, excluding: { e in e.eventIdentifier == target.event_id && abs(e.startDate.timeIntervalSince(originalStart)) < 1 })
                    result["conflict_check"] = check
                    guard check["status"] as? String == "clear" else { throw fail("改期目标与其他事项冲突，未保存") }
                }
            }
            guard mayWrite?() == true else { throw fail("执行窗口结束，未写入") }
            let expected = snapshot(event)
            result["save_status"] = "attempted"; result["status"] = "unknown"
            try persist(key, payload, result); attempted = true
            if action.operation == "delete" { try store.remove(event, span: span, commit: true) }
            else { try store.save(event, span: span, commit: true) }
            result["save_status"] = "saved"; result["saved_at"] = stamp(Date()); result["status"] = "saved_unverified"
            try persist(key, payload, result)
            result["verification_status"] = "unverified"
            let reader = stores.freshReader()
            guard !reader.calendars(for: .event).isEmpty else { throw fail("calendar_read_unavailable: 保存后日历接口不可读，无法验证结果；不会重复写入") }
            if action.operation == "delete" {
                guard try find(target, store: reader) == nil else { throw fail("删除后仍能查询到该次事件") }
                result["readback"] = ["absent": true, "coverage": "target_occurrence", "requested_scope": action.scope]
            } else {
                guard let id = event.eventIdentifier else { throw fail("保存后缺少标识") }
                let a = event.startDate!, b = event.endDate!
                let matches = reader.events(matching: reader.predicateForEvents(withStart: a, end: b, calendars: nil)).filter { $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince(a)) < 1 }
                guard matches.count == 1 else { throw fail("无法独立定位修改后的事件") }
                let read = snapshot(matches[0]); result["readback"] = read
                // Detaching a recurring occurrence can legitimately change its recurrence metadata.
                let keys = ["title", "start_at", "end_at", "time_zone", "is_all_day", "location", "notes", "url", "alarms", "calendar_id", "attendees"]
                func comparison(_ raw: [String: Any]) -> [String: Any] {
                    var value = raw.filter { keys.contains($0.key) }
                    let zone = TimeZone(identifier: source.query.time_zone)!
                    if raw["is_all_day"] as? Bool == true, let startText = raw["start_at"] as? String, let endText = raw["end_at"] as? String,
                       let start = try? parse(startText), let finish = try? parse(endText), let end = AllDayDates.exclusiveEnd(start: start, end: finish, zone: zone) {
                        value["end_at"] = stamp(end)
                        // All-day events may lose their explicit zone when stored as floating dates.
                        if raw["time_zone"] as? String == "" || raw["time_zone"] as? String == zone.identifier { value["time_zone"] = zone.identifier }
                    }
                    return value
                }
                let aData = try JSONSerialization.data(withJSONObject: comparison(expected), options: [.sortedKeys])
                let bData = try JSONSerialization.data(withJSONObject: comparison(read), options: [.sortedKeys])
                guard aData == bData else { throw fail("修改读回不一致，不自动重试") }
                result["event_id"] = id; result["verification_coverage"] = "target_occurrence"
            }
            result["status"] = action.scope == "future_events" ? "saved_unverified" : "verified"
            result["verification_status"] = action.scope == "future_events" ? "target_verified_series_unverified" : "verified"
            result["verified_at"] = stamp(Date())
            if action.scope == "future_events" { result["verification_note"] = "已按本次及以后调用 EventKit 并核验目标发生；未来整个系列尚未逐次读回，不能标为全部验证成功。" }
        } catch {
            result["error"] = ["message": error.localizedDescription]
            if attempted && result["save_status"] as? String != "saved" { result["save_status"] = "unknown"; result["status"] = "unknown" }
        }
        if rows[key] == nil || attempted {
            do { try persist(key, payload, result) }
            catch { result["persistence_error"] = error.localizedDescription; healthy = false }
        }
        return result
    }
}
