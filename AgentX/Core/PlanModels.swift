import Foundation

struct PlanField: Codable {
    let value: String?
    let source: String
    let evidence: String?
    let reason: String
    let critical: Bool
    let blocks_creation: Bool
}
struct PlanItem: Codable, Identifiable {
    let item_id: String
    let kind: String
    let fields: [String: PlanField]
    var alerts: AlertRequest? = nil // absent in historical v1 plans: never infer new reminders
    var calendar: CalendarFeatures? = nil // v3 only; historical plans keep their original semantics
    var id: String { item_id }
    var blocked: Bool { fields.values.contains { $0.blocks_creation } || calendar?.blocked == true }
    // Policy guardrails bound model defaults, without replacing its semantic judgment.
    func policyIssue(in batch: [PlanItem]) -> String? {
        guard !blocked else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let startText = fields["start_at"]?.value, let endText = fields["end_at"]?.value,
              let start = formatter.date(from: startText), let end = formatter.date(from: endText) else { return nil }
        // Reject duplicate series produced by expanding one multi-weekday instruction.
        // This is a guard, not a second natural-language parser or silent plan rewrite.
        if let c = calendar, c.recurrence.mode == "repeat", c.recurrence.frequency == "weekly" {
            var local = Calendar(identifier: .gregorian)
            if let name = fields["time_zone"]?.value, let zone = TimeZone(identifier: name) { local.timeZone = zone }
            for other in batch where other.id < id && !other.blocked {
                guard let o = other.calendar, o.recurrence.mode == "repeat",
                      c.recurrence.frequency == o.recurrence.frequency, c.recurrence.interval == o.recurrence.interval,
                      c.recurrence.weekdays.sorted() == o.recurrence.weekdays.sorted(),
                      c.recurrence.evidence == o.recurrence.evidence,
                      fields["title"]?.value == other.fields["title"]?.value,
                      fields["time_zone"]?.value == other.fields["time_zone"]?.value,
                      let otherText = other.fields["start_at"]?.value, let otherStart = formatter.date(from: otherText),
                      local.dateComponents([.hour,.minute,.second], from: start) == local.dateComponents([.hour,.minute,.second], from: otherStart),
                      abs(start.timeIntervalSince(otherStart)) < Double(c.recurrence.interval * 7) * 86400 else { continue }
                return "同一原文被拆成重叠重复系列，当前项未创建；请核对已生成系列"
            }
        }
        let defaulted = fields["start_at"]?.source == "defaulted" || fields["end_at"]?.source == "defaulted"
        guard defaulted else { return nil }
        if calendar?.is_all_day != true && end.timeIntervalSince(start) > 10800 { return "自主补齐的时长超过 3 小时上限，未创建" }
        for other in batch where other.id != id && !other.blocked {
            guard let otherStartText = other.fields["start_at"]?.value, let otherEndText = other.fields["end_at"]?.value,
                  let otherStart = formatter.date(from: otherStartText), let otherEnd = formatter.date(from: otherEndText) else { continue }
            let otherDefaulted = other.fields["start_at"]?.source == "defaulted" || other.fields["end_at"]?.source == "defaulted"
            if start < otherEnd && otherStart < end && (!otherDefaulted || other.id < id) {
                return "自主补齐的时段与本批 \(other.id) 冲突，未创建；未查询私人日历"
            }
        }
        return nil
    }
    func event(testMode: Bool) -> [String: Any] {
        var event: [String: Any] = ["item_id": item_id]
        for (key, field) in fields { if let value = field.value { event[key] = value } }
        if testMode, let title = event["title"] as? String { event["title"] = "AgentX Test " + title }
        if let alerts { event["alerts"] = alerts.wire }
        if let calendar { event["calendar"] = calendar.wire }
        return event
    }
}
struct CalendarPlan: Codable {
    let overflow: Bool
    let items: [PlanItem]
    func validate(text: String) throws {
        func reject(_ reason: String) -> NSError { NSError(domain: "AgentX.Plan", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
        guard items.count <= 8, !overflow || items.isEmpty else { throw reject("超过 8 项，整个计划未执行") }
        var ids = Set<String>()
        for item in items {
            try item.alerts?.validate(text: text)
            try item.calendar?.validate(text: text)
            guard item.item_id.range(of: "^i[1-8]$", options: .regularExpression) != nil,
                  ids.insert(item.item_id).inserted,
                  ["flexible", "appointment", "deadline", "other"].contains(item.kind),
                  Set(item.fields.keys) == Set(["title", "start_at", "end_at", "time_zone", "location"]) else { throw reject("候选字段或标识非法") }
            for (name, field) in item.fields {
                guard ["explicit", "inferred", "defaulted", "unresolved"].contains(field.source),
                      (field.value == nil) == (field.source == "unresolved"),
                      !field.reason.isEmpty, field.reason.count <= 500,
                      !(field.critical && field.source == "defaulted"),
                      !field.blocks_creation || field.value == nil else { throw reject("字段来源或重要事实补齐违规") }
                if let value = field.value { guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 300 else { throw reject("字段值非法") } }
                if let evidence = field.evidence { guard !evidence.isEmpty, text.contains(evidence) else { throw reject("引用不在原文中") } }
                if field.source == "explicit" && field.evidence == nil { throw reject("明确字段缺少原文依据") }
                if name != "location", field.value == nil, !field.blocks_creation { throw reject("必填空缺必须阻止创建") }
            }
        }
    }
}

// One atomic document includes original input, immutable plan, and actual execution results.
struct PlanJob: Codable, Identifiable {
    let submission_id: String
    let task_id: String
    let version: Int
    let text: String
    let submitted_at: String
    let time_zone: String
    let test_mode: Bool
    var state: String
    var message: String
    var plan: CalendarPlan?
    var planData: Data?
    var resultData: Data?
    var lease_id: String
    var assistant_id: String? = nil
    var route: ModuleRoute? = nil
    var review_status: String? = nil
    var query: CalendarQuery? = nil
    var queryResult: CalendarQueryResult? = nil // Exported only via a task-specific v5 answer context.
    var query_result_id: String? = nil
    var answer: ModelAnswer? = nil
    var completion_source_id: String? = nil // v8 only: explicit post-write data sharing.
    var completion_answer_state: String? = nil
    var completion_answer_error: String? = nil
    var answer_retry_id: String? = nil // User-requested answer-only attempt; never a write lease.
    var schedule: ScheduleDecision? = nil
    var schedule_request: ScheduleRequest? = nil
    var conversation_context: [ConversationTurn]? = nil
    var conversation_lookups: [ConversationLookup]? = nil
    var mutationSnapshot: MutationSnapshot? = nil
    var mutation: MutationDecision? = nil
    var scope: String { assistant_id ?? "calendar" }
    var id: String { submission_id }
    var request: [String: Any] {
        ["submission_id": submission_id, "task_id": task_id, "version": version, "text": text,
         "submitted_at": submitted_at, "time_zone": time_zone, "test_mode": test_mode, "lease_id": lease_id, "assistant_id": scope]
    }
    var wire: [String: Any] {
        var row = request
        if let conversation_context { row["conversation_context"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation_context)) }
        row["mutation_source_id"] = mutationSnapshot?.source_id
        if let mutation { row["mutation"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) }
        row["state"] = state; row["message"] = message
        row["review_status"] = review_status
        row["query_result_id"] = query_result_id
        row["completion_source_id"] = completion_source_id
        row["completion_answer_state"] = completion_answer_state
        row["completion_answer_error"] = completion_answer_error
        row["answer_retry_id"] = answer_retry_id
        if let schedule_request, let data = try? JSONEncoder().encode(schedule_request) { row["schedule_request"] = try? JSONSerialization.jsonObject(with: data) }
        if let schedule, let data = try? JSONEncoder().encode(schedule) { row["schedule"] = try? JSONSerialization.jsonObject(with: data) }
        if let answer, let data = try? JSONEncoder().encode(answer) { row["answer"] = try? JSONSerialization.jsonObject(with: data) }
        if let route, let data = try? JSONEncoder().encode(route) { row["route"] = try? JSONSerialization.jsonObject(with: data) }
        if let query, let data = try? JSONEncoder().encode(query) { row["query"] = try? JSONSerialization.jsonObject(with: data) }
        if let planData { row["plan"] = try? JSONSerialization.jsonObject(with: planData) }
        if let resultData { row["execution"] = try? JSONSerialization.jsonObject(with: resultData) }
        return row
    }
    func answerContext() throws -> [String: Any] {
        guard version >= 5, let queryResult, let source = query_result_id else { throw NSError(domain: "AgentX.Answer", code: 1, userInfo: [NSLocalizedDescriptionKey: "此任务没有可用于模型回答的查询结果；历史任务不会自动上传。"]) }
        return ["source_id": source, "tool_name": "calendar_query", "status": "query_complete",
                "result": try JSONSerialization.jsonObject(with: JSONEncoder().encode(queryResult))]
    }
    mutating func prepareCompletionAnswer() {
        guard version >= 8, resultData != nil, completion_source_id == nil,
              ["calendar", "calendar_schedule", "calendar_mutation"].contains(route?.kind ?? ""),
              ["verified", "partial", "not_completed", "unknown", "saved_unverified"].contains(state) else { return }
        completion_source_id = UUID().uuidString; completion_answer_state = "pending"
    }
    func completionContext() throws -> [String: Any] {
        guard version >= 8, let source = completion_source_id, let resultData,
              let raw = try JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let rows = raw["items"] as? [[String: Any]], rows.count <= 8 else {
            throw NSError(domain: "AgentX.Answer", code: 4, userInfo: [NSLocalizedDescriptionKey: "没有本轮可用于回答的执行记录；旧任务不自动上传"])
        }
        // Scope export to the requested items; omit identifiers, other events,
        // conversation history, device state and task markers appended to notes.
        let fields = Set(["item_id", "title", "operation", "scope", "status", "save_status", "verification_status", "saved_at", "verified_at", "error", "event_verification_status", "calendar_features_verification_status", "verification_coverage", "verification_note"])
        let readFields = Set(["title", "start_at", "end_at", "time_zone", "location", "is_all_day", "url", "alarms", "recurrence_rules", "absent", "coverage"])
        let exported = rows.map { row -> [String: Any] in
            var item = row.filter { fields.contains($0.key) }
            if let read = row["readback"] as? [String: Any] { item["readback"] = read.filter { readFields.contains($0.key) } }
            if let before = row["before"] as? [String: Any] { item["before"] = before.filter { readFields.contains($0.key) } }
            if let alerts = row["alerts"] as? [String: Any] {
                item["alerts"] = alerts.filter { ["configured", "readback", "verification_status", "user_requirement_status", "policy_message", "policy_complete", "notification_delivery"].contains($0.key) }
            }
            if let conflict = row["conflict_check"] as? [String: Any] {
                item["conflict_check"] = conflict.filter { ["status", "busy_count", "coverage", "occurrences_checked", "series_complete", "checked_until"].contains($0.key) }
            }
            return item
        }
        var context: [String: Any] = ["source_id": source, "tool_name": "calendar_execution", "status": state,
            "time_zone": time_zone, "result": ["status": raw["status"] ?? state, "items": exported]]
        if let planData { context["plan"] = try JSONSerialization.jsonObject(with: planData) }
        if let mutation { context["mutation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) }
        return context
    }
    mutating func acceptCompletionAnswer(_ value: ModelAnswer) throws {
        guard version >= 8, resultData != nil, completion_source_id == value.source_id,
              !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.text.count <= 4000,
              !value.model.isEmpty, value.model.count <= 150, ISO8601DateFormatter().date(from: value.generated_at) != nil else {
            throw NSError(domain: "AgentX.Answer", code: 5, userInfo: [NSLocalizedDescriptionKey: "回答与本次执行记录不匹配"])
        }
        if let old = answer {
            guard old == value else { throw NSError(domain: "AgentX.Answer", code: 6) }; return
        }
        guard completion_answer_state == "pending" else { throw NSError(domain: "AgentX.Answer", code: 7) }
        answer = value; completion_answer_state = "complete"
        completion_answer_error = nil
        // Prose must never promote partial/unknown execution to verified.
    }
    var canRetryAnswer: Bool {
        guard answer == nil else { return false }
        if completion_source_id != nil { return version >= 8 && resultData != nil && completion_answer_state == "failed" }
        return version >= 5 && query_result_id != nil && queryResult != nil && state == "answer_failed" && route?.kind == "calendar_query"
    }
    mutating func retryAnswer() throws {
        guard canRetryAnswer else { throw NSError(domain: "AgentX.Answer", code: 8, userInfo: [NSLocalizedDescriptionKey: "此任务没有可重试的失败答复"]) }
        answer_retry_id = UUID().uuidString
        if completion_source_id != nil {
            completion_answer_state = "pending"; completion_answer_error = nil
        } else {
            state = "answer_pending"; message = "正在根据已有查询结果重新生成答复；日历不会重新执行。"
        }
    }
    func validateAnswerAttempt(_ retryID: String?) throws {
        guard retryID == answer_retry_id else { throw NSError(domain: "AgentX.Answer", code: 9, userInfo: [NSLocalizedDescriptionKey: "旧答复尝试已失效"]) }
    }
    var conversationTurn: ConversationTurn {
        var events: [ConversationEvent] = []
        if let resultData, let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            for row in (result["items"] as? [[String: Any]] ?? []) where row["operation"] as? String != "delete" {
                let saved = row["save_status"] as? String
                guard saved == "saved" || saved == "unknown" || saved == "attempted" else { continue }
                let read = row["readback"] as? [String: Any]
                let payload = read ?? (row["request"] as? [String: Any]) ?? [:]
                if let title = payload["title"] as? String, let a = payload["start_at"] as? String, let b = payload["end_at"] as? String {
                    events.append(.init(title: title, start_at: a, end_at: b, history_ref: task_id + "/" + (row["item_id"] as? String ?? ""), source: read == nil ? "write_request_outcome_unknown" : "saved_readback",
                        save_status: saved, verification_status: row["verification_status"] as? String))
                }
            }
        }
        // A scheduling query lists pre-existing occupancy, not newly created events.
        if events.isEmpty, route?.kind == "calendar_query", let queryResult {
            events = queryResult.events.prefix(20).map { .init(title: $0.title, start_at: $0.start_at, end_at: $0.end_at, source: "queried_event") }
        }
        return .init(text: text, response: String((answer?.text ?? mutation?.message ?? schedule?.message ?? message).prefix(4000)) + "\n实际状态：" + state + "；" + message, state: state, events: events)
    }
    var conversationLookups: [ConversationLookup] {
        guard let resultData, let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else { return [] }
        return (result["items"] as? [[String: Any]] ?? []).compactMap { row in
            guard row["save_status"] as? String == "saved", row["operation"] as? String != "delete",
                  let id = row["event_id"] as? String, let item = row["item_id"] as? String,
                  let read = row["readback"] as? [String: Any] else { return nil }
            // Identifier lookup returns a series' first occurrence; never use it for recurring events.
            let single = (read["recurrence_count"] as? Int == 0) || ((read["recurrence"] as? [Any])?.isEmpty == true)
            guard single else { return nil }
            return .init(history_ref: task_id + "/" + item, event_id: id)
        }
    }
    mutating func acceptMutation(_ value: MutationDecision, windowActive: Bool) throws {
        guard version >= 7, route?.kind == "calendar_mutation", let snapshot = mutationSnapshot else { throw CalendarFeatures.invalid("没有匹配的修改候选") }
        try value.validate(snapshot: snapshot)
        if let old = mutation {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(old) == encoder.encode(value) else { throw CalendarFeatures.invalid("已有不同的不可变修改决策") }; return
        }
        guard state == "mutation_pending" else { throw CalendarFeatures.invalid("不在等待修改决策状态") }
        mutation = value
        state = value.decision == "execute" ? (windowActive ? "planned" : "window_expired") : (value.decision == "not_found" ? "not_completed" : "needs_clarification")
        message = value.decision == "execute" ? "修改/删除计划已保存，尚未执行；窗口过期需主动继续" : value.message
    }
    mutating func acceptSchedule(_ value: ScheduleDecision, windowActive: Bool) throws {
        try value.validate(job: self)
        if let old = schedule {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(old) == encoder.encode(value) else {
                throw NSError(domain: "AgentX.Schedule", code: 2, userInfo: [NSLocalizedDescriptionKey: "已有不可变排程，拒绝覆盖"])
            }
            return
        }
        guard state == "schedule_pending" else { throw NSError(domain: "AgentX.Schedule", code: 3, userInfo: [NSLocalizedDescriptionKey: "本任务不在等待排程状态"]) }
        schedule = value
        if let selected = value.plan {
            plan = selected; planData = try JSONEncoder().encode(selected)
            state = windowActive ? "planned" : "window_expired"
            message = windowActive ? "模型已依据空档选时，准备重新检查冲突并创建" : "排程已保存，尚未写入日历；请主动继续，同样会先重新检查冲突"
        } else {
            state = value.decision == "no_slot" ? "not_completed" : "needs_clarification"
            message = value.message
        }
    }
    mutating func acceptAnswer(_ value: ModelAnswer) throws {
        guard version >= 5, route?.kind != "calendar_schedule", queryResult != nil, query_result_id == value.source_id,
              !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.text.count <= 4000,
              !value.model.isEmpty, value.model.count <= 150,
              ISO8601DateFormatter().date(from: value.generated_at) != nil else {
            throw NSError(domain: "AgentX.Answer", code: 1, userInfo: [NSLocalizedDescriptionKey: "回答与实际查询结果不匹配。"])
        }
        if let old = answer {
            guard old == value else { throw NSError(domain: "AgentX.Answer", code: 2, userInfo: [NSLocalizedDescriptionKey: "已有不可变模型回答，拒绝覆盖。"]) }
            return
        }
        guard state == "answer_pending" else { throw NSError(domain: "AgentX.Answer", code: 3, userInfo: [NSLocalizedDescriptionKey: "本任务不在等待回答状态。"] ) }
        answer = value; state = "query_complete"; message = "模型已根据实际日历数据回答；本次没有写入日历。"
    }
}
struct ModelAnswer: Codable, Equatable {
    let text: String
    let source_id: String
    let model: String
    let generated_at: String
}
final class PlanStore {
    let directory: URL
    var url: URL { directory.appendingPathComponent("jobs.json") }
    init(directory: URL) { self.directory = directory }
    func load() throws -> [PlanJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PlanJob].self, from: Data(contentsOf: url))
    }
    func save(_ jobs: [PlanJob]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
    }
}

// Foreground inference may take longer than the finite OS background allowance.
// Returning after expiry never rearms the lease; repeated switches do not renew it.
struct CalendarSessionWindow {
    let foregroundDeadline: Date
    private(set) var backgroundDeadline: Date?
    private(set) var deadline: Date
    init(now: Date) {
        foregroundDeadline = now.addingTimeInterval(300)
        deadline = foregroundDeadline
    }
    mutating func transition(foreground: Bool, now: Date) -> Bool {
        guard deadline > now else { return false }
        if foreground { deadline = foregroundDeadline }
        else {
            if backgroundDeadline == nil { backgroundDeadline = min(foregroundDeadline, now.addingTimeInterval(45)) }
            deadline = backgroundDeadline!
        }
        return deadline > now
    }
}

// Only background execution needs an OS assertion; inactive transitions defer.
enum CalendarExecutionPolicy {
    static func allows(foreground: Bool, background: Bool, sessionActive: Bool,
                       storageHealthy: Bool, windowRemaining: TimeInterval,
                       hasBackgroundAssertion: Bool, backgroundRemaining: TimeInterval) -> Bool {
        guard sessionActive, storageHealthy, windowRemaining > 5 else { return false }
        if foreground { return true }
        return background && hasBackgroundAssertion && backgroundRemaining > 5
    }
}

// Bound to a persisted phone snapshot; selection is supplied by the model.
struct ScheduleRequest: Codable, Equatable {
    struct Item: Codable, Equatable { let item_id: String; let title: String; let evidence: String }
    let time_authority: String
    let reason: String
    let items: [Item]
    func validate(text: String) throws {
        guard time_authority == "self_directed", !reason.isEmpty, reason.count <= 500, (1...8).contains(items.count),
              items.enumerated().allSatisfy({ offset, item in
                  item.item_id == "i\(offset + 1)" && !item.title.isEmpty && item.title.count <= 200 && !item.evidence.isEmpty && item.evidence.count <= 500 && text.contains(item.evidence)
              }) else { throw NSError(domain: "AgentX.Schedule", code: 4, userInfo: [NSLocalizedDescriptionKey: "排程清单缺失或不允许自主决定时间"]) }
    }
}

struct ScheduleDecision: Codable {
    let source_id: String
    let decision: String
    let message: String
    let plan: CalendarPlan?

    func validate(job: PlanJob) throws {
        func reject(_ text: String) -> NSError { NSError(domain: "AgentX.Schedule", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard job.version >= 6, job.route?.kind == "calendar_schedule",
              source_id == job.query_result_id, let manifest = job.schedule_request, let result = job.queryResult,
              result.request.mode == "free_slots", !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.count <= 1500 else { throw reject("排程与真实空档快照不匹配") }
        try manifest.validate(text: job.text)
        if ["no_slot", "needs_clarification"].contains(decision) {
            guard plan == nil else { throw reject("未安排的决策不能携带写入计划") }; return
        }
        guard decision == "scheduled", let plan, !plan.overflow, plan.items.count == manifest.items.count else { throw reject("排程计划为空或不支持") }
        try plan.validate(text: job.text)
        let iso = ISO8601DateFormatter()
        let zone = TimeZone(identifier: result.request.time_zone)!
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone; format.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        var spans: [CalendarAvailability.Span] = []
        for item in plan.items {
            guard manifest.items.contains(where: { $0.item_id == item.item_id && $0.title == item.fields["title"]?.value }),
                  !item.blocked, item.alerts != nil, let features = item.calendar,
                  features.is_all_day == (result.request.slot_kind == "all_day"), features.recurrence.mode == "none", features.unsupported.isEmpty,
                  item.fields["time_zone"]?.value == result.request.time_zone,
                  let a = item.fields["start_at"], let b = item.fields["end_at"],
                  a.source == "defaulted", b.source == "defaulted", !a.critical, !b.critical,
                  let aText = a.value, let bText = b.value, let start = iso.date(from: aText), let end = iso.date(from: bText),
                  format.string(from: start) == aText.replacingOccurrences(of: "+00:00", with: "Z"),
                  format.string(from: end) == bText.replacingOccurrences(of: "+00:00", with: "Z"),
                  end > start else { throw reject("自动排程时长、来源或日历能力不符合约束") }
            if result.request.slot_kind == "all_day" {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
                guard cal.startOfDay(for: start) == start, cal.startOfDay(for: end) == end,
                      cal.dateComponents([.day], from: start, to: end).day == (result.request.duration_days ?? 1) else { throw reject("全天排程须使用完整当地日期与排他结束日") }
            } else {
                guard end.timeIntervalSince(start) == Double(result.request.duration_minutes * 60), end.timeIntervalSince(start) <= 10800 else { throw reject("自动排程时长不符") }
            }
            guard result.free_slots.contains(where: { slot in
                guard let lo = iso.date(from: slot.start_at), let hi = iso.date(from: slot.end_at) else { return false }
                return lo <= start && start < end && end <= hi
            }) else { throw reject("模型选择的时间不在真实候选空档内") }
            let span = CalendarAvailability.Span(start: start, end: end)
            guard !spans.contains(where: { CalendarAvailability.overlaps($0, span) }) else { throw reject("自动排程事项相互冲突") }
            spans.append(span)
        }
    }
}
