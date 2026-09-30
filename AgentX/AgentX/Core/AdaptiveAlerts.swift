import Foundation

// Pure Foundation contract/policy: shared by the host, EventKit adapter and tests.
struct AlertSpec: Codable {
    let alert_id: String
    let trigger_type: String
    let offset_seconds: Int?
    let at: String?
    let source: String
    let evidence: String?
    let reason: String
}

struct AlertRequest: Codable {
    let mode: String // explicit, disabled, suggested, unresolved
    let evidence: String?
    let reason: String
    let count_limit: Int?
    let no_extra: Bool
    let overflow: Bool // more than the 16-entry representation cap; never truncate and execute
    let items: [AlertSpec]

    func validate(text: String? = nil) throws {
        func bad() -> NSError { NSError(domain: "AgentX.Alerts", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid reminder contract or provenance"]) }
        func quote(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && (text == nil || text!.contains(value))
        }
        guard ["explicit", "disabled", "suggested", "unresolved"].contains(mode),
              !reason.isEmpty, reason.count <= 500, quote(evidence),
              items.count <= 16, count_limit == nil || (0...10000).contains(count_limit!),
              !overflow || items.isEmpty else { throw bad() }
        if ["explicit", "disabled"].contains(mode) && (evidence == nil || !no_extra) { throw bad() }
        if ["disabled", "unresolved"].contains(mode) && (!items.isEmpty || overflow) { throw bad() }
        if mode == "disabled" && count_limit != 0 { throw bad() }
        if mode == "explicit" && items.isEmpty && !overflow { throw bad() }
        var ids = Set<String>()
        for item in items {
            guard item.alert_id.range(of: "^a([1-9]|1[0-6])$", options: .regularExpression) != nil,
                  ids.insert(item.alert_id).inserted, ["relative", "absolute"].contains(item.trigger_type),
                  item.source == (mode == "explicit" ? "explicit" : "defaulted"),
                  !item.reason.isEmpty, item.reason.count <= 500, quote(item.evidence),
                  item.source != "explicit" || item.evidence != nil else { throw bad() }
            // Invalid offsets/times are evaluated per reminder, not as event failures.
        }
    }
    var wire: [String: Any] { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:] }
}

struct ResolvedAlert {
    let id: String
    let type: String
    let offset: Int?
    let fire: Date
    var wire: [String: Any] {
        ["alert_id": id, "trigger_type": type, "offset_seconds": offset as Any? ?? NSNull(),
         "trigger_at": AlertPolicy.format(fire)]
    }
}

struct AlertEvaluation {
    let request: AlertRequest?
    let configured: [ResolvedAlert]
    let decisions: [[String: Any]]
    let complete: Bool
    let reason: String?
    var wire: [String: Any] {
        ["contract_version": 2, "requested": request?.wire as Any? ?? NSNull(),
         "mode": request?.mode ?? "legacy_none", "configured": configured.map(\.wire),
         "decisions": decisions, "policy_complete": complete, "policy_reason": reason as Any? ?? NSNull(),
         "policy_message": reason.map(AlertPolicy.message) as Any? ?? NSNull(),
         "user_requirement_status": request?.mode == "suggested" || request == nil ? "not_specified" : (complete ? "pending_verification" : "unmet"),
         "verification_status": "not_attempted", "notification_delivery": "not_observed",
         "minimum_lead_seconds": AlertPolicy.minimumLeadSeconds]
    }
}

enum AlertPolicy {
    static let minimumLeadSeconds: TimeInterval = 300
    static let maximumCount = 2
    static func message(_ code: String) -> String {
        ["unresolved_instruction": "提醒要求不明确或互相矛盾，未设置",
         "unsupported_count_no_subset": "去重后的提醒超过两次或用户次数限制，未擅自选择子集",
         "invalid_time_or_after_start": "提醒时间、时区或提前量无效，或晚于事件开始",
         "past_reminder": "提醒时间已过去，未改成即时提醒",
         "absolute_alarm_on_series": "重复系列暂不支持单个绝对日期提醒，未改成每次重复提醒",
         "minimum_lead_not_met": "距离当前不足五分钟，未设置，以免执行时打扰用户"][code] ?? code
    }
    static let tolerance: TimeInterval = 1 // strictly less than one second

    static func format(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func absolute(_ text: String, zone: TimeZone) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
              let date = ISO8601DateFormatter().date(from: text) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f.string(from: date) == text ? date : nil
    }
    static func evaluate(_ request: AlertRequest?, start: Date, zone: TimeZone, now: Date, recurring: Bool = false) -> AlertEvaluation {
        guard let request else { return AlertEvaluation(request: nil, configured: [], decisions: [], complete: true, reason: nil) }
        var decisions: [[String: Any]] = [], unique: [ResolvedAlert] = []
        var complete = true
        func result(_ configured: [ResolvedAlert], _ ok: Bool, _ reason: String? = nil) -> AlertEvaluation {
            AlertEvaluation(request: request, configured: configured, decisions: decisions.map { row in
                var row = row
                if let code = row["code"] as? String { row["message"] = message(code) }
                return row
            }, complete: ok, reason: reason)
        }
        if request.mode == "unresolved" { return result([], false, "unresolved_instruction") }
        if request.mode == "disabled" { return result([], true) }
        if request.overflow { return result([], false, "unsupported_count_no_subset") }
        for a in request.items.sorted(by: { $0.alert_id < $1.alert_id }) {
            var row: [String: Any] = ["alert_id": a.alert_id, "source": a.source, "reason": a.reason]
            if recurring && a.trigger_type == "absolute" {
                row["status"] = "not_configured"; row["code"] = "absolute_alarm_on_series"
                decisions.append(row); complete = false; continue
            }
            let fire: Date?
            if a.trigger_type == "relative", let seconds = a.offset_seconds, a.at == nil, seconds <= 0, seconds >= -315360000 {
                fire = start.addingTimeInterval(Double(seconds))
            } else if a.trigger_type == "absolute", a.offset_seconds == nil, let at = a.at {
                fire = absolute(at, zone: zone)
            } else { fire = nil }
            guard let fire, fire <= start else {
                row["status"] = "not_configured"; row["code"] = "invalid_time_or_after_start"
                decisions.append(row); complete = false; continue
            }
            row["trigger_at"] = format(fire)
            if let prior = unique.first(where: { abs($0.fire.timeIntervalSince(fire)) < tolerance }) {
                row["status"] = "deduplicated"; row["duplicate_of"] = prior.id
                decisions.append(row); continue
            }
            unique.append(ResolvedAlert(id: a.alert_id, type: a.trigger_type, offset: a.offset_seconds, fire: fire))
            row["status"] = "candidate"; decisions.append(row)
        }
        // Count the distinct requested times BEFORE removing past/too-near times:
        // an over-limit explicit request must never silently become a chosen subset.
        let limit = min(maximumCount, request.count_limit ?? maximumCount)
        if unique.count > limit {
            for i in decisions.indices where decisions[i]["status"] as? String == "candidate" {
                decisions[i]["status"] = "not_configured"; decisions[i]["code"] = "unsupported_count_no_subset"
            }
            return result([], false, "unsupported_count_no_subset")
        }
        var configured: [ResolvedAlert] = []
        for a in unique {
            let i = decisions.firstIndex { $0["alert_id"] as? String == a.id }!
            if a.fire.timeIntervalSince(now) < minimumLeadSeconds {
                complete = false; decisions[i]["status"] = "not_configured"
                decisions[i]["code"] = a.fire <= now ? "past_reminder" : "minimum_lead_not_met"
            } else { configured.append(a); decisions[i]["status"] = "configured" }
        }
        return result(configured.sorted { $0.fire < $1.fire }, complete)
    }
    // Compare instants, not array order or relative-vs-absolute representation.
    // All raw readback types/offsets are separately retained by the EventKit adapter.
    static func matches(_ expected: [Date], _ actual: [Date], unsupported: Bool = false) -> Bool {
        guard !unsupported, expected.count == actual.count else { return false }
        return zip(expected.sorted(), actual.sorted()).allSatisfy { abs($0.timeIntervalSince($1)) < tolerance }
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AgentX.Alerts", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid persisted request object"])
        }
        return object
    }
    static func canonicalPayload(_ object: [String: Any]) throws -> Data {
        var copy = object
        if var alerts = copy["alerts"] as? [String: Any], let rows = alerts["items"] as? [[String: Any]] {
            alerts["items"] = rows.sorted { ($0["alert_id"] as? String ?? "") < ($1["alert_id"] as? String ?? "") }
            copy["alerts"] = alerts
        }
        if var calendar = copy["calendar"] as? [String: Any], var recurrence = calendar["recurrence"] as? [String: Any] {
            for key in ["weekdays", "month_days", "months"] {
                if let values = recurrence[key] as? [Int] { recurrence[key] = values.sorted() }
            }
            calendar["recurrence"] = recurrence; copy["calendar"] = calendar
        }
        return try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])
    }
    static func canonicalPlan(_ object: [String: Any]) throws -> Data {
        var copy = object
        if let items = copy["items"] as? [[String: Any]] {
            copy["items"] = try items.map { try JSONSerialization.jsonObject(with: canonicalPayload($0)) }
        }
        return try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])
    }
}
