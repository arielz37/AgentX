import Foundation

struct ConversationTurn: Codable {
    let text: String
    let response: String
    let state: String
    let events: [ConversationEvent]
}
struct ConversationEvent: Codable {
    let title: String
    let start_at: String
    let end_at: String
    var history_ref: String? = nil
    var source: String? = nil
    var save_status: String? = nil
    var verification_status: String? = nil
}
struct ConversationLookup: Codable {
    let history_ref: String
    let event_id: String // Device-only; never in model context. Single occurrences only.
}
struct MutationCandidate: Codable {
    let target_ref: String
    let event_id: String // Device-local lookup only; removed from model context.
    let fingerprint: String
    let title: String
    let start_at: String
    let end_at: String
    let time_zone: String
    let is_all_day: Bool
    let calendar_name: String
    let writable: Bool
    let recurring: Bool
    let location: String?
    let notes: String?
    let url: String?
    var related_history_refs: [String]? = nil
    var modelWire: [String: Any] {
        var row = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
        row.removeValue(forKey: "event_id"); row.removeValue(forKey: "fingerprint")
        return row
    }
}
struct MutationSnapshot: Codable {
    let source_id: String
    let queried_at: String
    let query: CalendarQuery
    let candidates: [MutationCandidate]
    var context: [String: Any] {
        ["source_id": source_id, "tool_name": "calendar_mutation_candidates", "queried_at": queried_at,
         "query": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(query))) ?? [:],
         "candidates": candidates.map(\.modelWire)]
    }
}
struct EventPatch: Codable {
    var title: String? = nil
    var start_at: String? = nil
    var end_at: String? = nil
    var time_zone: String? = nil
    var is_all_day: Bool? = nil
    var location: String? = nil // null/omitted keeps old value; empty string clears.
    var notes: String? = nil
    var url: String? = nil
    var reminder_offsets_seconds: [Int]? = nil // [] removes alarms; nil preserves.
    var isEmpty: Bool { title == nil && start_at == nil && end_at == nil && time_zone == nil && is_all_day == nil && location == nil && notes == nil && url == nil && reminder_offsets_seconds == nil }
}
struct MutationAction: Codable {
    let item_id: String
    let target_ref: String
    let operation: String
    let scope: String
    let patch: EventPatch?
}
struct MutationDecision: Codable {
    let source_id: String
    let decision: String
    let message: String
    let actions: [MutationAction]
    func validate(snapshot: MutationSnapshot) throws {
        func reject() -> NSError { NSError(domain: "AgentX.Mutation", code: 1, userInfo: [NSLocalizedDescriptionKey: "修改/删除决策与实际候选不匹配"]) }
        guard source_id == snapshot.source_id, !message.isEmpty, message.count <= 2000,
              ["execute", "needs_clarification", "not_found"].contains(decision), actions.count <= 8 else { throw reject() }
        if decision != "execute" { guard actions.isEmpty else { throw reject() }; return }
        guard !actions.isEmpty else { throw reject() }
        var ids = Set<String>(), targets = Set<String>()
        for (index, action) in actions.enumerated() {
            guard action.item_id == "i\(index + 1)", ids.insert(action.item_id).inserted,
                  targets.insert(action.target_ref).inserted,
                  let target = snapshot.candidates.first(where: { $0.target_ref == action.target_ref }), target.writable,
                  ["update", "delete"].contains(action.operation), ["this_event", "future_events"].contains(action.scope),
                  target.recurring || action.scope == "this_event" else { throw reject() }
            let wanted = Set(snapshot.query.target_history_refs ?? [])
            guard wanted.isEmpty || !wanted.isDisjoint(with: target.related_history_refs ?? []) else { throw CalendarFeatures.invalid("实际候选不是本轮已绑定的历史事项，不能换成其他事件") }
            let linked = (target.related_history_refs ?? []).contains { ref in snapshot.candidates.filter { ($0.related_history_refs ?? []).contains(ref) }.count == 1 }
            if !linked {
                func signature(_ c: MutationCandidate) throws -> Data {
                    var value = c.modelWire; value.removeValue(forKey: "target_ref"); value.removeValue(forKey: "related_history_refs")
                    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                }
                let selected = Set(actions.map(\.target_ref)), key = try signature(target)
                for other in snapshot.candidates where other.target_ref != target.target_ref {
                    if try signature(other) == key && !selected.contains(other.target_ref) { throw CalendarFeatures.invalid("候选内容相同且没有唯一历史关联，需澄清后再操作") }
                }
            }
            if action.operation == "delete" { guard action.patch == nil else { throw reject() } }
            else { guard let patch = action.patch, !patch.isEmpty else { throw reject() } }
        }
    }
}
