import Foundation

@main struct CompletionAnswerValidation {
    static func reject(_ action: () throws -> Void) { do { try action(); fatalError("Expected rejection") } catch {} }
    static func main() throws {
        let result: [String: Any] = ["status": "partial", "host": ["private_device": "omit"], "items": [
            ["item_id": "i1", "status": "verified", "save_status": "saved", "verification_status": "verified", "event_id": "private-id",
             "readback": ["title": "测试事项", "start_at": "2030-10-05T08:00:00Z", "notes": "private task marker", "calendar_id": "private-calendar"]],
            ["item_id": "i2", "status": "saved_unverified", "save_status": "saved", "verification_status": "failed"],
            ["item_id": "i3", "status": "failed", "save_status": "not_attempted", "verification_status": "not_attempted"]]]
        func task(_ version: Int) throws -> PlanJob {
            var j = PlanJob(submission_id: "test", task_id: "test", version: version, text: "帮我安排这三件事", submitted_at: "2030-10-01T00:00:00Z", time_zone: "Asia/Shanghai", test_mode: true, state: "partial", message: "原始执行摘要", resultData: try JSONSerialization.data(withJSONObject: result), lease_id: "expired", assistant_id: "calendar")
            j.route = ModuleRoute(kind: "calendar", message: "创建计划", supported: ["calendar"], unsupported: [])
            return j
        }
        var legacy = try task(7); legacy.prepareCompletionAnswer()
        precondition(legacy.completion_source_id == nil); reject { _ = try legacy.completionContext() }
        var job = try task(8); job.prepareCompletionAnswer()
        // The original wire plan retains explicit JSON nulls. Synthesized Swift
        // Codable would omit nil optionals; export must match the frozen wire.
        job.planData = Data(#"{"overflow":false,"items":[{"item_id":"i1","kind":"flexible","fields":{"location":{"value":null,"source":"unresolved","evidence":null,"reason":"未提供","critical":false,"blocks_creation":false}}}]}"#.utf8)
        let id = job.completion_source_id!; job.prepareCompletionAnswer(); precondition(job.completion_source_id == id)
        let context = try job.completionContext()
        let exportedPlan = try JSONSerialization.data(withJSONObject: context["plan"]!, options: [.sortedKeys])
        let originalPlan = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: job.planData!), options: [.sortedKeys])
        precondition(exportedPlan == originalPlan)
        let text = String(data: try JSONSerialization.data(withJSONObject: context), encoding: .utf8)!
        precondition(!text.contains("private") && !text.contains("conversation_context"))
        let rows = (context["result"] as! [String: Any])["items"] as! [[String: Any]]
        precondition(rows.count == 3 && rows[1]["save_status"] as? String == "saved" && rows[1]["verification_status"] as? String == "failed")
        let original = job.resultData
        reject { try job.retryAnswer() } // Pending requests cannot reset their own budget.
        job.completion_answer_state = "failed"; job.completion_answer_error = "复核失败"
        let originalLease = job.lease_id, frozenPlan = job.planData
        try job.retryAnswer()
        let retryID = job.answer_retry_id!
        precondition(job.completion_answer_state == "pending" && job.completion_answer_error == nil)
        precondition(job.completion_source_id == id && job.resultData == original && job.planData == frozenPlan)
        precondition(job.lease_id == originalLease && job.state == "partial")
        reject { try job.validateAnswerAttempt(nil) }
        reject { try job.validateAnswerAttempt("stale-attempt") }
        try job.validateAnswerAttempt(retryID)
        reject { try job.retryAnswer() }
        let answer = ModelAnswer(text: "第一件办好了，第二件已保存但尚未核验，第三件没添加。", source_id: id, model: "test", generated_at: "2030-10-01T00:00:01Z")
        reject { try job.acceptCompletionAnswer(.init(text: "错误", source_id: "wrong", model: "test", generated_at: answer.generated_at)) }
        var restored = try JSONDecoder().decode(PlanJob.self, from: JSONEncoder().encode(job))
        try restored.acceptCompletionAnswer(answer); try restored.acceptCompletionAnswer(answer)
        reject { try restored.retryAnswer() }
        precondition(restored.answer_retry_id == retryID)
        precondition(restored.state == "partial" && restored.resultData == original && restored.completion_answer_state == "complete")
        reject { try restored.acceptCompletionAnswer(.init(text: "全完成了", source_id: id, model: "test", generated_at: answer.generated_at)) }
        precondition(restored.wire["completion_source_id"] as? String == id)
        print("PASS completion answer: explicit v8 export, private IDs omitted, partial outcome preserved, source binding, immutable/idempotent delivery, expired lease permits answer only, persistence roundtrip.")
    }
}
