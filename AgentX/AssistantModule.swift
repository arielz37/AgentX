import SwiftUI

enum AssistantModule: String, Identifiable, CaseIterable, Hashable {
    case auto, calendar
    var id: String { rawValue }
    var title: String { self == .auto ? "全能助手" : "日程助手" }
    var subtitle: String { self == .auto ? "说出需求，帮你选择能力" : "查询、安排、修改与删除日程" }
    var icon: String { self == .auto ? "sparkles" : "calendar" }
    var color: Color { self == .auto ? Color(red: 0.37, green: 0.32, blue: 0.90) : Color(red: 0.04, green: 0.53, blue: 0.43) }
    var welcome: String { self == .auto ? "你说想做什么，\n我来找到合适的助手。" : "把安排说给我，\n接下来交给日程助手。" }
    var detail: String { self == .auto ? "可以查询日程、寻找空闲或创建安排。其他能力正在准备中。" : "可以查询已有日程、检查冲突和寻找空闲；支持修改、删除与上下文追问，也支持重复、提醒和备注。重要信息会保留空缺。" }
    var examples: [String] { self == .auto ? ["明天下午两点到三点练琴，提前一小时提醒。", "明天有哪些安排？"] : ["明天有哪些安排？", "下周帮我找个空闲时间安排一小时练琴，不用提醒。", "后天下午三点到四点整理书架，不用提醒。"] }
}

extension PlanJob {
    var module: AssistantModule { AssistantModule(rawValue: scope) ?? .calendar }
    var stateTitle: String {
        ["mutation_pending":"正在确认目标与改动", "mutation_failed":"修改决策未完成", "schedule_pending":"正在依据空档排程", "schedule_failed":"排程未完成", "answer_pending":"正在回答", "answer_failed":"回答未完成", "query_complete":"查询完成", "queued":"等待接收", "parsing":"理解与复核中", "planned":"准备执行", "executing":"手机执行中", "verified":"已完成", "saved_unverified":"已保存，验证未完整", "partial":"部分完成", "not_completed":"未完成", "failed":"处理失败", "window_expired":"等待继续", "unknown":"结果待核对", "scope_mismatch":"建议切换助手", "unsupported":"暂不支持", "needs_clarification":"需要补充说明", "mixed":"包含未支持的需求"][state] ?? "等待处理"
    }
    var running: Bool { ["queued", "parsing", "planned", "executing", "answer_pending", "schedule_pending", "mutation_pending"].contains(state) }
    var resultRows: [[String: Any]] { ((resultData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["items"] as? [[String: Any]]) ?? [] }
    var verifiedCount: Int { resultRows.filter { $0["status"] as? String == "verified" }.count }
    var savedCount: Int { resultRows.filter { $0["save_status"] as? String == "saved" }.count }
}
