import Foundation

struct ModuleRoute: Codable {
    let kind: String
    let message: String
    let supported: [String]
    let unsupported: [String]
}
enum AgentXRouting {
    static func validate(_ route: ModuleRoute, hasPlan: Bool, review: String, scope: String) throws {
        func reject() -> NSError { NSError(domain: "AgentX.Route", code: 1, userInfo: [NSLocalizedDescriptionKey: "能力判断或复核结果不完整，未执行"]) }
        guard ["auto", "calendar"].contains(scope), ["passed", "corrected"].contains(review),
              ["calendar", "unsupported", "clarify", "mixed"].contains(route.kind),
              !route.message.isEmpty, route.message.count <= 800,
              route.supported.count <= 8, route.unsupported.count <= 8,
              route.supported.allSatisfy({ $0 == "calendar" }),
              route.unsupported.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else { throw reject() }
        if route.kind == "calendar" {
            guard hasPlan, route.supported == ["calendar"], route.unsupported.isEmpty else { throw reject() }
        } else {
            guard !hasPlan else { throw reject() }
            if route.kind == "mixed" { guard route.supported == ["calendar"], !route.unsupported.isEmpty else { throw reject() } }
            if route.kind == "clarify" { guard route.supported.isEmpty, route.unsupported.isEmpty else { throw reject() } }
            if route.kind == "unsupported" { guard route.supported.isEmpty, !route.unsupported.isEmpty else { throw reject() } }
        }
    }
    static func terminalState(_ kind: String, scope: String) -> String {
        switch kind {
        case "unsupported": return scope == "calendar" ? "scope_mismatch" : "unsupported"
        case "mixed": return "mixed"
        default: return "needs_clarification"
        }
    }
}
