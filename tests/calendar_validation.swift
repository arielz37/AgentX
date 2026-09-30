import Foundation

@main struct ValidationChecks {
    static func main() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z")!
        let valid: [String: Any] = ["item_id": "piano", "title": "AgentX Test piano",
            "start_at": "2026-09-28T14:00:00+08:00", "end_at": "2026-09-28T15:00:00+08:00", "time_zone": "Asia/Shanghai"]
        _ = try CalendarEventInput(valid, now: now)
        let invalid: [(String, Any)] = [
            ("end_at", "2026-09-28T13:00:00+08:00"),
            ("end_at", "2026-09-28T14:00:00+08:00"),
            ("start_at", "2026-09-27T14:00:00+08:00"),
            ("start_at", "2026-09-28T14:00:00"),
            ("start_at", "2026-09-28T14:00:00+09:00"),
            ("start_at", "2026-02-30T14:00:00+08:00"),
            ("time_zone", "Moon/Base"), ("title", "Real appointment"),
            ("attendees", ["someone@example.com"]),
            ("end_at", "2026-09-30T14:00:00+08:00")]
        for (field, value) in invalid {
            var item = valid; item[field] = value
            do { _ = try CalendarEventInput(item, now: now); fatalError("Accepted invalid \(field): \(value)") }
            catch { }
        }
        print("PASS: valid future event and 10 invalid schema/time/side-effect cases")
    }
}
