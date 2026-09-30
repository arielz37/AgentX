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
    var scope: String { assistant_id ?? "calendar" }
    var id: String { submission_id }
    var request: [String: Any] {
        ["submission_id": submission_id, "task_id": task_id, "version": version, "text": text,
         "submitted_at": submitted_at, "time_zone": time_zone, "test_mode": test_mode, "lease_id": lease_id, "assistant_id": scope]
    }
    var wire: [String: Any] {
        var row = request
        row["state"] = state; row["message"] = message
        row["review_status"] = review_status
        if let route, let data = try? JSONEncoder().encode(route) { row["route"] = try? JSONSerialization.jsonObject(with: data) }
        if let planData { row["plan"] = try? JSONSerialization.jsonObject(with: planData) }
        if let resultData { row["execution"] = try? JSONSerialization.jsonObject(with: resultData) }
        return row
    }
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

// The existing 45-second submission lease applies in both modes. Only background
// execution needs an OS assertion and remaining OS budget; inactive transitions defer.
enum CalendarExecutionPolicy {
    static func allows(foreground: Bool, background: Bool, sessionActive: Bool,
                       storageHealthy: Bool, windowRemaining: TimeInterval,
                       hasBackgroundAssertion: Bool, backgroundRemaining: TimeInterval) -> Bool {
        guard sessionActive, storageHealthy, windowRemaining > 5 else { return false }
        if foreground { return true }
        return background && hasBackgroundAssertion && backgroundRemaining > 5
    }
}
