import Foundation

@main struct AlertsValidation {
    static func main() throws {
        let f = ISO8601DateFormatter()
        let now = f.date(from: "2030-09-27T00:00:00Z")!
        let start = now.addingTimeInterval(172800)
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        func alarm(_ id: String, _ offset: Int? = nil, at: String? = nil, source: String = "explicit") -> AlertSpec {
            AlertSpec(alert_id: id, trigger_type: at == nil ? "relative" : "absolute", offset_seconds: offset, at: at, source: source, evidence: source == "explicit" ? "要求" : nil, reason: "测试")
        }
        func request(_ rows: [AlertSpec], mode: String = "explicit", limit: Int? = nil) -> AlertRequest {
            AlertRequest(mode: mode, evidence: mode == "suggested" ? nil : "要求", reason: "测试", count_limit: mode == "disabled" ? 0 : limit, no_extra: true, overflow: false, items: rows)
        }
        func evaluate(_ r: AlertRequest?, _ s: Date? = nil) -> AlertEvaluation { AlertPolicy.evaluate(r, start: s ?? start, zone: zone, now: now) }
        let one = request([alarm("a1", -86400)])
        try one.validate(text: "要求")
        precondition(evaluate(one).configured.count == 1 && evaluate(one).complete)
        precondition(evaluate(request([alarm("a1", -7200)])).configured[0].fire == start.addingTimeInterval(-7200))
        let two = request([alarm("a1", -86400), alarm("a2", -7200)])
        precondition(evaluate(two).configured.count == 2)
        precondition(evaluate(request([alarm("a1", -600)], limit: 1)).configured.count == 1)
        precondition(evaluate(request([], mode: "disabled")).complete)
        precondition(evaluate(nil).configured.isEmpty)
        precondition(evaluate(request([alarm("a1", -600, source: "defaulted")], mode: "suggested")).complete)
        precondition(evaluate(request([alarm("a1", -86400, source: "defaulted"), alarm("a2", -7200, source: "defaulted")], mode: "suggested")).configured.count == 2)
        let absText = "2030-09-28T09:00:00+08:00"
        precondition(evaluate(request([alarm("a1", at: absText)])).configured[0].fire == f.date(from: absText))
        let partial = evaluate(two, now.addingTimeInterval(10800))
        precondition(!partial.complete && partial.configured.count == 1)
        precondition(partial.wire["user_requirement_status"] as? String == "unmet")
        precondition(evaluate(request([alarm("a1", 0)]), now.addingTimeInterval(299)).configured.isEmpty)
        precondition(evaluate(request([alarm("a1", 0)]), now.addingTimeInterval(300)).configured.count == 1)
        let three = request([alarm("a1", -86400), alarm("a2", -7200), alarm("a3", -600)])
        precondition(evaluate(three).configured.isEmpty && !evaluate(three).complete)
        // Three distinct requests stay unsupported even when one is already past.
        precondition(evaluate(three, now.addingTimeInterval(10800)).reason == "unsupported_count_no_subset")
        let duplicates = request([alarm("a1", -7200), alarm("a2", -7200), alarm("a3", -600)])
        precondition(evaluate(duplicates).configured.count == 2 && evaluate(duplicates).complete)
        precondition(evaluate(request([alarm("a1", -7200), alarm("a2", -600)], limit: 1)).configured.isEmpty)
        for invalid in [alarm("a1", 1), alarm("a1", at: "2030-09-28T09:00:00+09:00"), alarm("a1", at: "2030-02-30T09:00:00+08:00"), alarm("a1", nil)] {
            precondition(!evaluate(request([invalid])).complete && evaluate(request([invalid])).configured.isEmpty)
        }
        // Civil previous-day 09:00 and elapsed 24h differ around DST.
        let ny = TimeZone(identifier: "America/New_York")!
        let dstStart = f.date(from: "2030-03-10T09:00:00-04:00")!
        let previousMorning = AlertPolicy.absolute("2030-03-09T09:00:00-05:00", zone: ny)!
        precondition(dstStart.timeIntervalSince(previousMorning) == 23 * 3600)
        let dst = AlertPolicy.evaluate(one, start: dstStart, zone: ny, now: dstStart.addingTimeInterval(-200000))
        precondition(dst.configured[0].fire != previousMorning)
        precondition(AlertPolicy.absolute("2030-03-10T02:30:00-05:00", zone: ny) == nil)
        let expected = evaluate(two).configured.map(\.fire)
        precondition(AlertPolicy.matches(expected, Array(expected.reversed())))
        precondition(!AlertPolicy.matches(expected, Array(expected.prefix(1))))
        precondition(!AlertPolicy.matches(expected, expected + [start]))
        precondition(!AlertPolicy.matches(expected, expected.map { $0.addingTimeInterval(2) }))
        precondition(!AlertPolicy.matches(expected, expected, unsupported: true))
        precondition(!AlertPolicy.matches(expected, [expected[0], expected[0]]))
        precondition(AlertPolicy.matches([], []))
        let raw: [String: Any] = ["item_id": "i1", "title": "AgentX Test", "alerts": two.wire]
        var reordered = raw; var a = two.wire; a["items"] = Array((a["items"] as! [[String: Any]]).reversed()); reordered["alerts"] = a
        let c1 = try AlertPolicy.canonicalPayload(raw), c2 = try AlertPolicy.canonicalPayload(reordered)
        precondition(c1 == c2)
        var changed = raw; changed["alerts"] = one.wire
        let c3 = try AlertPolicy.canonicalPayload(changed); precondition(c1 != c3)
        let legacy: [String: Any] = ["item_id": "i1", "title": "old"]
        let legacyCanonical = try AlertPolicy.canonicalPayload(legacy), legacyOriginal = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        precondition(legacyCanonical == legacyOriginal)
        let unresolved = request([], mode: "unresolved")
        precondition(!evaluate(unresolved).complete && evaluate(unresolved).configured.isEmpty)
        print("PASS adaptive reminders: provenance, 0/1/2/count, time policy, DST, readback equality, canonical dedup and legacy payload")
    }
}
