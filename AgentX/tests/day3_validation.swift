import Foundation
@main struct Day3Validation {
    static func main() throws {
        func allowed(_ foreground: Bool, _ background: Bool, _ active: Bool = true, _ healthy: Bool = true,
                     _ remaining: Double = 40, _ assertion: Bool = true, _ osBudget: Double = 20) -> Bool {
            CalendarExecutionPolicy.allows(foreground: foreground, background: background,
                sessionActive: active, storageHealthy: healthy, windowRemaining: remaining,
                hasBackgroundAssertion: assertion, backgroundRemaining: osBudget)
        }
        precondition(allowed(true, false, true, true, 40, false, 0)) // foreground doesn't need OS background budget
        precondition(allowed(false, true)) // same active lease continues in background
        precondition(!allowed(false, false)) // app switch transition defers
        precondition(!allowed(false, true, true, true, 40, true, 4)) // OS deadline
        precondition(!allowed(true, false, true, true, 0)) // returning can't revive expired task
        precondition(!allowed(true, false, false))
        precondition(!allowed(true, false, true, false))
        precondition(allowed(true, false, true, true, 25)) // returning before expiry keeps lease
        let now = ISO8601DateFormatter().date(from: "2026-09-27T04:00:00Z")!
        let item: [String: Any] = ["item_id": "i1", "title": "练琴", "start_at": "2026-09-27T14:00:00+08:00", "end_at": "2026-09-27T15:00:00+08:00", "time_zone": "Asia/Shanghai", "location": "家里"]
        _ = try CalendarEventInput(item, now: now, productMode: true, testMode: false)
        for (name, value) in [("start_at", "2026-09-27T09:00:00+08:00"), ("end_at", "2026-09-27T13:00:00+08:00"), ("time_zone", "Moon/Base"), ("start_at", "2026-09-27T14:00:00+09:00"), ("attendees", "anyone")] {
            var bad=item; bad[name]=value
            do { _ = try CalendarEventInput(bad, now: now, productMode: true, testMode: false); fatalError("accepted invalid \(name)") } catch { }
        }
        func f(_ value: String?, _ source: String, _ critical: Bool = false, _ blocks: Bool = false) -> PlanField {
            PlanField(value: value, source: source, evidence: nil, reason: "测试说明", critical: critical, blocks_creation: blocks)
        }
        var fields = ["title": f("练琴", "inferred"), "start_at": f(nil, "unresolved", true, true), "end_at": f(nil, "unresolved", false, true), "time_zone": f("Asia/Shanghai", "inferred"), "location": f(nil, "unresolved")]
        let candidate = PlanItem(item_id: "i1", kind: "appointment", fields: fields)
        let plan = CalendarPlan(overflow: false, items: [candidate]); try plan.validate(text: "明天有钢琴课")
        precondition(candidate.blocked)
        fields["start_at"] = f("2026-09-28T14:00:00+08:00", "defaulted", true)
        do { try CalendarPlan(overflow: false, items: [PlanItem(item_id: "i1", kind: "appointment", fields: fields)]).validate(text: "课程"); fatalError("defaulted critical accepted") } catch { }
        var flexibleFields = fields
        flexibleFields["start_at"] = f("2026-09-28T08:00:00+08:00", "defaulted")
        flexibleFields["end_at"] = f("2026-09-28T19:00:00+08:00", "defaulted")
        let overlong = PlanItem(item_id: "i2", kind: "flexible", fields: flexibleFields)
        precondition(overlong.policyIssue(in: [overlong]) != nil)
        flexibleFields["start_at"] = f("2026-09-28T09:00:00+08:00", "defaulted")
        flexibleFields["end_at"] = f("2026-09-28T10:00:00+08:00", "defaulted")
        let flexible = PlanItem(item_id: "i2", kind: "flexible", fields: flexibleFields)
        var explicitFields = flexibleFields
        explicitFields["start_at"] = f("2026-09-28T09:30:00+08:00", "inferred")
        explicitFields["end_at"] = f("2026-09-28T10:30:00+08:00", "inferred")
        let fixed = PlanItem(item_id: "i1", kind: "appointment", fields: explicitFields)
        precondition(flexible.policyIssue(in: [fixed, flexible]) != nil)
        precondition(fixed.policyIssue(in: [fixed, flexible]) == nil)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store=PlanStore(directory: folder)
        let job=PlanJob(submission_id: "test", task_id: "test", version: 1, text: "原始输入", submitted_at: "time", time_zone: "Asia/Shanghai", test_mode: true, state: "window_expired", message: "未执行", plan: plan, planData: try JSONEncoder().encode(plan), lease_id: "lease")
        try store.save([job]); let restored=try store.load(); precondition(restored[0].plan!.items[0].blocked && restored[0].text == "原始输入")
        print("PASS Day3: today future, time/side-effect rejection, critical-null blocking, provenance, durable plan roundtrip")
    }
}
