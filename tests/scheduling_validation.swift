import Foundation
@main struct SchedulingValidation {
    static func main() throws {
        let raw = #"""
{"job": {"submission_id": "ax-answer-test", "task_id": "ax-answer-test", "version": 6, "assistant_id": "calendar", "text": "10月2日下午两点到六点找空档帮我安排一小时整理书架，不用提醒。", "submitted_at": "2030-09-30T12:00:00Z", "time_zone": "Asia/Shanghai", "test_mode": true, "lease_id": "lease1", "state": "schedule_pending", "message": "日历已读取", "query": {"mode": "free_slots", "start_at": "2030-10-02T14:00:00+08:00", "end_at": "2030-10-02T18:00:00+08:00", "time_zone": "Asia/Shanghai", "duration_minutes": 60, "day_start_minute": 840, "day_end_minute": 1080, "assumptions": []}, "query_result_id": "snapshot-1", "execution": {"status": "query_complete", "items": []}, "route": {"kind": "calendar_schedule", "message": "先查询再排程", "supported": ["calendar"], "unsupported": []}, "schedule_request": {"time_authority": "self_directed", "reason": "自行整理可以自由选时", "items": [{"item_id": "i1", "title": "整理书架", "evidence": "安排一小时整理书架"}]}, "queryResult": {"request": {"mode": "free_slots", "start_at": "2030-10-02T14:00:00+08:00", "end_at": "2030-10-02T18:00:00+08:00", "time_zone": "Asia/Shanghai", "duration_minutes": 60, "day_start_minute": 840, "day_end_minute": 1080, "assumptions": []}, "queried_at": "2030-09-30T12:00:10Z", "event_count": 2, "busy_count": 1, "calendar_count": 2, "events": [{"title": "国庆假期", "start_at": "2030-10-01T16:00:00Z", "end_at": "2030-10-02T16:00:00Z", "is_all_day": true, "calendar_name": "中国大陆节假日", "blocks_time": false, "occupancy_reason": "只读节假日订阅仅展示，不占时"}, {"title": "整理书架", "start_at": "2030-10-02T07:00:00Z", "end_at": "2030-10-02T08:00:00Z", "is_all_day": false, "calendar_name": "个人", "blocks_time": true, "occupancy_reason": "个人安排"}], "events_truncated": false, "free_slots": [{"start_at": "2030-10-02T06:00:00Z", "end_at": "2030-10-02T07:00:00Z"}, {"start_at": "2030-10-02T08:00:00Z", "end_at": "2030-10-02T10:00:00Z"}], "slots_truncated": false, "scope_note": "当前手机日历快照；空档没有预留。"}}, "decision": {"source_id": "snapshot-1", "decision": "scheduled", "message": "建议在已有安排之后整理一小时；具体时间由空档自动选择，尚未保存。", "plan": {"overflow": false, "items": [{"item_id": "i1", "kind": "flexible", "fields": {"title": {"value": "整理书架", "source": "inferred", "evidence": null, "reason": "测试上下文", "critical": false, "blocks_creation": false}, "start_at": {"value": "2030-10-02T16:00:00+08:00", "source": "defaulted", "evidence": null, "reason": "测试上下文", "critical": false, "blocks_creation": false}, "end_at": {"value": "2030-10-02T17:00:00+08:00", "source": "defaulted", "evidence": null, "reason": "测试上下文", "critical": false, "blocks_creation": false}, "time_zone": {"value": "Asia/Shanghai", "source": "inferred", "evidence": null, "reason": "测试上下文", "critical": false, "blocks_creation": false}, "location": {"value": null, "source": "unresolved", "evidence": null, "reason": "测试上下文", "critical": false, "blocks_creation": false}}, "alerts": {"mode": "disabled", "evidence": "不用提醒", "reason": "用户要求", "count_limit": 0, "no_extra": true, "overflow": false, "items": []}, "calendar": {"is_all_day": false, "notes": null, "url": null, "unsupported": [], "reason": "单次定时", "recurrence": {"mode": "none", "frequency": null, "interval": 1, "weekdays": [], "month_days": [], "months": [], "end_type": "never", "count": null, "until": null, "evidence": null, "reason": "未要求重复"}}}]}}}
"""#
        let fixture = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        func decode<T: Decodable>(_ object: Any, _ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object)) }
        func rejects(_ body: () throws -> Void) { do { try body(); fatalError("expected rejection") } catch {} }
        let original = try decode(fixture["job"]!, PlanJob.self)
        let decision = try decode(fixture["decision"]!, ScheduleDecision.self)
        try decision.validate(job: original)
        var job = original
        try job.acceptSchedule(decision, windowActive: true)
        precondition(job.state == "planned" && job.plan != nil && job.queryResult != nil && job.planData != nil)
        try job.acceptSchedule(decision, windowActive: false) // Lost response must not change state/plan.
        precondition(job.state == "planned")
        let changed = ScheduleDecision(source_id: decision.source_id, decision: decision.decision, message: "changed", plan: decision.plan)
        rejects { try job.acceptSchedule(changed, windowActive: true) }
        var expired = original
        try expired.acceptSchedule(decision, windowActive: false)
        precondition(expired.state == "window_expired" && expired.plan != nil)
        // Restart must retain pending selection source and immutable stored plan.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PlanStore(directory: folder); try store.save([original, expired])
        let restored = try store.load()
        precondition(restored[0].state == "schedule_pending" && restored[1].schedule?.source_id == decision.source_id)
        var restoredJob = restored[1]; try restoredJob.acceptSchedule(decision, windowActive: true)
        precondition(restoredJob.state == "window_expired") // Delivery doesn't rearm a lease.
        var noSlot = original
        let none = ScheduleDecision(source_id: decision.source_id, decision: "no_slot", message: "没有合适空档，没有创建", plan: nil)
        try noSlot.acceptSchedule(none, windowActive: true); try noSlot.acceptSchedule(none, windowActive: true)
        precondition(noSlot.state == "not_completed" && noSlot.plan == nil)
        rejects { try ScheduleDecision(source_id: "stale", decision: decision.decision, message: decision.message, plan: decision.plan).validate(job: original) }
        for (start, end) in [("15:00:00", "16:00:00"), ("14:30:00", "15:30:00"), ("16:00:00", "18:00:00")] {
            var rawDecision = fixture["decision"] as! [String: Any]
            var plan = rawDecision["plan"] as! [String: Any]
            var items = plan["items"] as! [[String: Any]]
            var fields = items[0]["fields"] as! [String: [String: Any]]
            fields["start_at"]!["value"] = "2030-10-02T" + start + "+08:00"
            fields["end_at"]!["value"] = "2030-10-02T" + end + "+08:00"
            items[0]["fields"] = fields; plan["items"] = items; rawDecision["plan"] = plan
            let bad = try decode(rawDecision, ScheduleDecision.self)
            rejects { try bad.validate(job: original) }
        }
        rejects { try job.acceptAnswer(ModelAnswer(text: "pretend created", source_id: decision.source_id, model: "test", generated_at: "2030-09-30T12:00:00Z")) }
        print("PASS scheduling: actual-slot containment, duration, stale source rejection, durable/idempotent delivery, expired lease not rearmed, no-slot no write, answer cannot finalize scheduling.")
    }
}
