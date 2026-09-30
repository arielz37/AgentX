import SwiftUI

struct PlanReportView: View {
    let job: PlanJob
    let continueAction: () -> Void
    private var rows: [[String: Any]] { ((job.resultData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["items"] as? [[String: Any]]) ?? [] }
    private let labels = ["title": "标题", "start_at": "开始", "end_at": "结束", "time_zone": "时区", "location": "地点"]
    var body: some View {
        List {
            Section("任务") { Text(job.text); Text(job.message); Text(job.stateTitle).font(.caption)
                if let route = job.route { Text(route.message).font(.subheadline) }
                if let review = job.review_status { Text(review == "corrected" ? "模型已复核并修正" : "模型已复核").font(.caption) }
                if job.state == "window_expired", (job.plan != nil || job.query != nil) { Button("继续执行这份计划", action: continueAction) }
            }
            if let mutation = job.mutation {
                Section("修改/删除决策") { Text(mutation.message).textSelection(.enabled) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Section(row["title"] as? String ?? "日历事项") {
                        Text("操作：\(row["operation"] as? String ?? "") · 结果：\(row["status"] as? String ?? "未执行")")
                        Text("保存：\(row["save_status"] as? String ?? "未尝试") · 核验：\(row["verification_status"] as? String ?? "未尝试")")
                        Text("范围：\(row["scope"] as? String ?? "")；读回覆盖：\(row["verification_coverage"] as? String ?? "目标发生项")").font(.caption)
                        if let note = row["verification_note"] as? String { Text(note).foregroundStyle(.orange) }
                        if let failure = row["persistence_error"] as? String { Text("记录持久化失败：" + failure).foregroundStyle(.orange) }
                        if let error = row["error"] as? [String: Any] { Text(error["message"] as? String ?? "").foregroundStyle(.orange) }
                        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { DisclosureGroup("查看真实前后记录") { Text(text).font(.caption.monospaced()).textSelection(.enabled) } }
                    }
                }
            }
            if let schedule = job.schedule {
                Section("模型选时依据") {
                    Text(schedule.message).textSelection(.enabled)
                    Text("模型选择是计划；是否保存、读回验证和发生新冲突，以下方实际执行结果为准。").font(.caption)
                    Text("依据快照：\(schedule.source_id)").font(.caption2)
                }
            }
            if let answer = job.answer {
                Section("模型回答") {
                    Text(answer.text).textSelection(.enabled)
                    Text("模型：\(answer.model) · 生成于 \(answer.generated_at)").font(.caption)
                    Text("接口数据与模型理解分开记录；模型仍可能理解有误。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result = job.queryResult { Section { CalendarQueryView(result: result, sharedForModelAnswer: job.version >= 5) } }
            ForEach(job.plan?.items ?? []) { item in
                Section(item.fields["title"]?.value ?? "标题空缺") {
                    let row = rows.first { $0["item_id"] as? String == item.id }
                    Text("执行：\(row?["status"] as? String ?? (["unknown", "executing"].contains(job.state) ? "结果未知，等待核验" : "未执行"))")
                    Text("保存：\(row?["save_status"] as? String ?? (["unknown", "executing"].contains(job.state) ? "未知" : "未尝试")) · 验证：\(row?["verification_status"] as? String ?? (["unknown", "executing"].contains(job.state) ? "未知" : "未尝试"))").font(.caption)
                    if let check = row?["conflict_check"] as? [String: Any] {
                        Text("写入前冲突检查").font(.headline)
                        Text(check["status"] as? String == "conflict" ? "已有日程占用，本项未创建，没有自动改期。" : "检查时该时段未发现占用；不是持续监控或空闲预留。")
                        if let n = check["occurrences_checked"] as? Int { Text("已检查 \(n) 次发生，截止 \(check["checked_until"] as? String ?? "")").font(.caption) }
                        if check["coverage"] as? String == "one_year_horizon" { Text("仅检查一年内重复发生；更远日期未检查。").font(.caption).foregroundStyle(.orange) }
                        if check["coverage"] as? String == "first_occurrence_only" { Text("重复系列仅检查首次发生，后续各次仍可能冲突。").font(.caption).foregroundStyle(.orange) }
                        if let note = check["suggestion_note"] as? String, !note.isEmpty { Text(note).font(.caption) }
                        ForEach(Array((check["suggestions"] as? [[String: String]] ?? []).enumerated()), id: \.offset) { _, slot in
                            Text("可选区间：\(slot["start_at"] ?? "") → \(slot["end_at"] ?? "")").font(.caption)
                        }
                    } else if job.version < 4 { Text("历史任务：未检查已有日历冲突。").font(.caption).foregroundStyle(.secondary) }
                    if let c = item.calendar {
                        Text("日历设置").font(.headline)
                        Text(c.is_all_day ? "全天（结束日期为不包含的次日）" : "定时事件")
                        Text("重复：\(c.recurrence.summary)")
                        Text(c.recurrence.reason).font(.caption)
                        Text("备注：\(c.notes ?? "未提供")")
                        Text("链接：\(c.url ?? "未提供")")
                        Text(c.reason).font(.caption)
                        if !c.unsupported.isEmpty { Text("尚不支持，未创建：" + c.unsupported.joined(separator: "；")).foregroundStyle(.orange) }
                        Text("以上为计划要求；保存与实际读回结果见本项下方记录。").font(.caption)
                    }
                    if let a = item.alerts {
                        Text("提醒：\(alertMode(a.mode))").font(.headline)
                        Text(a.reason).font(.caption)
                        if let quote = a.evidence { Text("依据：\(quote)").font(.caption) }
                        ForEach(a.items, id: \.alert_id) { alarm in
                            Text("\(alarm.alert_id)：\(alarmDescription(alarm)) · \(alarm.source == "explicit" ? "用户明确要求" : "系统建议")").font(.caption)
                            Text(alarm.reason).font(.caption)
                        }
                        if a.items.isEmpty { Text(a.mode == "disabled" ? "用户要求不提醒" : "无具体提醒配置").font(.caption) }
                        if let actual = row?["alerts"] as? [String: Any] {
                            Text("提醒读回：\(actual["verification_status"] as? String ?? "未验证") · 用户要求：\(actual["user_requirement_status"] as? String ?? "未知")").font(.caption)
                            if let reason = actual["policy_message"] as? String { Text("未完成原因：\(reason)").font(.caption) }
                            ForEach(Array((actual["decisions"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, decision in
                                Text("\(decision["alert_id"] as? String ?? "")：\(decision["status"] as? String ?? "") \(decision["trigger_at"] as? String ?? "") \(decision["message"] as? String ?? "")").font(.caption)
                            }
                            ForEach(Array((actual["readback"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, alarm in
                                Text("实际读回提醒：\(alarm["trigger_at"] as? String ?? "")（\(alarm["trigger_type"] as? String ?? "")）").font(.caption)
                            }
                        } else { Text("提醒尚未执行，以上只是请求或建议").font(.caption) }
                        Text("已配置不等于通知已送达；受日历通知和专注模式等设置影响。").font(.caption)
                    } else { Text("历史无提醒计划；未进行新版提醒验收。").font(.caption) }
                    fieldGroup("自动补齐", item: item, sources: ["defaulted"])
                    fieldGroup("仍然空缺", item: item, sources: ["unresolved"])
                    fieldGroup("原文与上下文推导", item: item, sources: ["explicit", "inferred"])
                    if let failure = row?["error"] as? [String: Any], let text = failure["message"] as? String { Text(text).foregroundStyle(.red) }
                    if let read = row?["readback"] as? [String: Any] {
                        Text("实际读回：\(read["title"] as? String ?? "")\n\(read["start_at"] as? String ?? "") → \(read["end_at"] as? String ?? "")").font(.caption)
                        if item.calendar != nil {
                            Text("日历扩展读回验证：\(row?["calendar_features_verification_status"] as? String ?? "未验证")").font(.caption)
                            Text("全天：\(read["is_all_day"] as? Bool == true ? "是" : "否") · 重复规则：\(read["recurrence_count"] as? Int ?? 0) 条").font(.caption)
                            Text("实际备注：\(read["notes"] as? String ?? "无")").font(.caption)
                            Text("实际链接：\(read["url"] as? String ?? "无")").font(.caption)
                            if let rules = read["recurrence_rules"] as? [[String: Any]], !rules.isEmpty {
                                DisclosureGroup("查看实际重复规则") {
                                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                                        Text(ruleDescription(rule)).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("执行报告")
    }
    private func ruleDescription(_ rule: [String: Any]) -> String {
        let unit = ["daily":"天", "weekly":"周", "monthly":"月", "yearly":"年"][rule["frequency"] as? String ?? ""] ?? "未知周期"
        var text = "每 \(rule["interval"] as? Int ?? 1) \(unit)"
        let names = [1:"一", 2:"二", 3:"三", 4:"四", 5:"五", 6:"六", 7:"日"]
        let days = (rule["weekdays"] as? [[String: Int]] ?? []).compactMap { $0["day"] }.map { "周" + (names[$0] ?? "?") }
        if !days.isEmpty { text += " · " + days.joined(separator: "、") }
        if let count = rule["end_count"] as? Int, count > 0 { text += " · 共 \(count) 次" }
        if let date = rule["end_at"] as? String { text += " · 截止 " + date }
        return text
    }
    private func alertMode(_ mode: String) -> String {
        ["explicit": "用户明确要求", "disabled": "用户明确禁止", "suggested": "系统建议", "unresolved": "无法确定"][mode] ?? mode
    }
    private func alarmDescription(_ a: AlertSpec) -> String {
        if a.trigger_type == "absolute" { return a.at ?? "时间空缺" }
        guard let seconds = a.offset_seconds else { return "提前量空缺" }
        if seconds == 0 { return "事件开始时" }
        if seconds % 86400 == 0 { return "提前 \(-seconds / 86400) 天（每一天按24小时）" }
        if seconds % 3600 == 0 { return "提前 \(-seconds / 3600) 小时" }
        return "提前 \(-seconds / 60) 分钟"
    }
    @ViewBuilder private func fieldGroup(_ title: String, item: PlanItem, sources: [String]) -> some View {
        Text(title).font(.headline)
        if !item.fields.values.contains(where: { sources.contains($0.source) }) { Text("无").font(.caption) }
        ForEach(["title", "start_at", "end_at", "time_zone", "location"], id: \.self) { name in
                        if let field = item.fields[name], sources.contains(field.source) {
                            VStack(alignment: .leading) {
                                Text("\(labels[name] ?? name)：\(field.value ?? "空缺")")
                                if let evidence = field.evidence { Text("原文：\(evidence)").font(.caption) }
                                Text("\(field.source == "defaulted" ? "自动补齐" : field.source == "inferred" ? "上下文推导" : field.source == "unresolved" ? "仍然空缺" : "来自原文") · \(field.reason)\(field.blocks_creation ? " · 阻止创建" : "")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
    }
}
