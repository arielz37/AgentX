import Foundation
@main struct RoutingValidation {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var window = CalendarSessionWindow(now: now)
        precondition(window.deadline == now.addingTimeInterval(300))
        precondition(window.transition(foreground: false, now: now.addingTimeInterval(60)))
        precondition(window.deadline == now.addingTimeInterval(105))
        precondition(window.transition(foreground: true, now: now.addingTimeInterval(70)))
        precondition(window.deadline == now.addingTimeInterval(300))
        precondition(window.transition(foreground: false, now: now.addingTimeInterval(80)))
        precondition(window.deadline == now.addingTimeInterval(105)) // no renewed background lease
        precondition(!window.transition(foreground: true, now: now.addingTimeInterval(106)))
        var expiredForeground = CalendarSessionWindow(now: now)
        precondition(!expiredForeground.transition(foreground: true, now: now.addingTimeInterval(301)))
        func route(_ kind: String) -> ModuleRoute { ModuleRoute(kind: kind, message: "测试", supported: ["calendar", "mixed"].contains(kind) ? ["calendar"] : [], unsupported: ["mixed", "unsupported"].contains(kind) ? ["邮件发送"] : []) }
        func rejects(_ block: () throws -> Void) { do { try block(); fatalError("expected rejection") } catch {} }
        for scope in ["auto", "calendar"] {
            try AgentXRouting.validate(route("calendar"), hasPlan: true, review: "passed", scope: scope)
            for kind in ["mixed", "unsupported", "clarify"] {
                try AgentXRouting.validate(route(kind), hasPlan: false, review: "corrected", scope: scope)
                rejects { try AgentXRouting.validate(route(kind), hasPlan: true, review: "passed", scope: scope) }
            }
        }
        rejects { try AgentXRouting.validate(route("calendar"), hasPlan: true, review: "failed", scope: "auto") }
        rejects { try AgentXRouting.validate(route("calendar"), hasPlan: true, review: "passed", scope: "sms") }
        rejects { try AgentXRouting.validate(route("calendar"), hasPlan: false, review: "passed", scope: "auto") }
        precondition(AgentXRouting.terminalState("unsupported", scope: "calendar") == "scope_mismatch")
        precondition(AgentXRouting.terminalState("unsupported", scope: "auto") == "unsupported")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PlanStore(directory: folder)
        let job = PlanJob(submission_id: "ax-test", task_id: "ax-test", version: 3, text: "测试", submitted_at: "2030-09-27T12:00:00Z", time_zone: "Asia/Shanghai", test_mode: true, state: "unsupported", message: "不支持", lease_id: "lease", assistant_id: "auto", route: route("unsupported"), review_status: "passed")
        try store.save([job]); let read = try PlanStore(directory: folder).load()
        precondition(read.count == 1 && read[0].scope == "auto" && read[0].route?.kind == "unsupported" && read[0].plan == nil)
        precondition(read[0].request["assistant_id"] as? String == "auto")
        precondition(read[0].wire["review_status"] as? String == "passed")
        print("AgentX native route rejection and persistent task roundtrip: PASS")
    }
}
