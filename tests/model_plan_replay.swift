// Checks live model artifacts with the same Swift validators used on the phone.
// Foundation only: never imports EventKit or accesses the user's calendar.
import Foundation

@main struct ModelPlanReplay {
    struct Record: Decodable {
        struct Request: Decodable { let text: String; let submitted_at: String }
        struct Result: Decodable { let route: ModuleRoute; let plan: CalendarPlan? }
        let request: Request
        let result: Result
    }
    static func main() throws {
        guard CommandLine.arguments.count > 1 else { fatalError("Provide local model replay JSON paths") }
        for path in CommandLine.arguments.dropFirst() {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let plan = record.result.plan, record.result.route.kind == "calendar" else { fatalError("Expected a creation plan") }
            try plan.validate(text: record.request.text)
            let now = ISO8601DateFormatter().date(from: record.request.submitted_at)!
            for item in plan.items {
                guard !item.blocked, item.policyIssue(in: plan.items) == nil else { fatalError("Unexpected blocked item: \(item.item_id)") }
                _ = try CalendarEventInput(item.event(testMode: true), now: now, productMode: true)
            }
            print("PASS native plan and per-item validation: \(plan.items.count) items; no calendar access")
        }
    }
}
