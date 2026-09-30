import Foundation
import EventKit

// Fault injection, not an assertion about iOS's undocumented connection limit.
@main struct EventStoreLifetimeValidation {
    @MainActor static func main() async throws {
        EKEventStore.reset()
        EKEventStore.instanceLimit = 2
        EKEventStore.cacheReads = true
        EKEventStore.copyReadEvents = true
        let stores = CalendarEventStores()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bridge = CalendarBridge(executionLocation: "iphone_native_app", ledgerURL: folder.appendingPathComponent("ledger.json"), stores: stores)
        bridge.mayWrite = { true }; bridge.checkConflicts = true; bridge.comprehensiveConflicts = true
        _ = try await bridge.handle("calendar_lock", [:])
        let status = try await bridge.handle("calendar_status", [:])
        let session = status["session_id"] as! String
        let zone = TimeZone(identifier: "Africa/Abidjan")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let anchor = cal.startOfDay(for: Date())
        let none = RecurrenceRequest(mode: "none", frequency: nil, interval: 1, weekdays: [], month_days: [], months: [], end_type: "never", count: nil, until: nil, evidence: nil, reason: "无重复")
        let items: [[String: Any]] = (1...8).map { n in
            let day = cal.date(byAdding: .day, value: n * 4, to: anchor)!
            let allDay = n == 4 || n == 5
            let start = allDay ? day : day.addingTimeInterval(Double(n == 6 ? 23 : 7) * 3600)
            let end = start.addingTimeInterval(allDay ? Double(n == 5 ? 2 : 1) * 86400 : Double(n == 6 ? 2 : 1) * 3600)
            let repeatRule = RecurrenceRequest(mode: "repeat", frequency: "weekly", interval: 1, weekdays: [(cal.component(.weekday, from: start) + 5) % 7 + 1], month_days: [], months: [], end_type: "count", count: 4, until: nil, evidence: "每周四次", reason: "测试重复")
            let features = CalendarFeatures(is_all_day: allDay, notes: nil, url: nil, recurrence: n == 7 ? repeatRule : none, reason: "批量生命周期测试", unsupported: [])
            return ["item_id": "i\(n)", "title": "AgentX Test lifetime \(n)", "start_at": AlertPolicy.format(start), "end_at": AlertPolicy.format(end), "time_zone": zone.identifier, "calendar": features.wire]
        }
        let params: [String: Any] = ["session_id": session, "task_id": "eight-item-lifetime", "test_mode": true, "items": items]
        let result = try await bridge.handle("calendar_execute", params)
        let rows = result["items"] as! [[String: Any]]
        precondition(rows.count == 8 && rows.allSatisfy { $0["status"] as? String == "verified" })
        precondition(EKEventStore.instances == 2 && EKEventStore.saves == 8)
        precondition(EKEventStore.queries == 8 && EKEventStore.resetCalls >= 24)
        precondition(EKEventStore.writtenStoreIDs.isDisjoint(with: EKEventStore.queriedStoreIDs))
        _ = try await bridge.handle("calendar_execute", params)
        precondition(EKEventStore.instances == 2 && EKEventStore.saves == 8)

        // Same reusable reader must see a manual change, not a previous cache.
        let reader = CalendarReader(stores: stores)
        let q = CalendarQuery(mode: "events", start_at: AlertPolicy.format(anchor), end_at: AlertPolicy.format(anchor.addingTimeInterval(60 * 86400)), time_zone: zone.identifier, duration_minutes: 60, day_start_minute: 0, day_end_minute: 1440, assumptions: [])
        _ = try reader.query(q)
        let saved = EKEventStore.events.values.first!
        saved.title = "AgentX Test manually changed"
        let changed = try reader.query(q)
        precondition(changed.events.contains { $0.title == "AgentX Test manually changed" })
        EKEventStore.events.removeValue(forKey: saved.eventIdentifier!)
        let deleted = try reader.query(q)
        precondition(deleted.event_count == 7 && !deleted.events.contains { $0.title == "AgentX Test manually changed" })

        // Empty calendars cannot be treated as a successful delete verification.
        EKEventStore.calendarList = []
        do { _ = try reader.query(q); fatalError("Empty store must fail closed") }
        catch { precondition(error.localizedDescription.contains("calendar_read_unavailable")) }
        precondition(EKEventStore.instances == 2)
        print("PASS EventKit lifetime TEST DOUBLE: eight mixed items with two stores; fresh independent readback; cache reset sees manual changes/deletion; dedup preserves save count; unavailable calendars fail closed.")
    }
}
