import SwiftUI

struct CalendarQueryView: View {
    let result: CalendarQueryResult
    var compact = false
    var sharedForModelAnswer = false
    private var request: CalendarQuery { result.request }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.mode == "free_slots" ? "空闲时段建议" : request.mode == "conflicts" ? "时段占用" : "已有日程", systemImage: request.mode == "free_slots" ? "clock" : "calendar")
                .font(.headline)
            Text("\(time(request.start_at)) → \(time(request.end_at))").font(.caption).foregroundStyle(.secondary)
            Text("时区：\(request.time_zone) · 查询于 \(time(result.queried_at))").font(.caption).foregroundStyle(.secondary)
            if request.mode == "free_slots" {
                Text(request.slot_kind == "all_day" ? "连续 \(request.duration_days ?? 1) 个完整当地日" : "每天 \(clock(request.day_start_minute))–\(clock(request.day_end_minute))，至少 \(request.duration_minutes) 分钟").font(.subheadline)
                if result.free_slots.isEmpty { Text("该范围和每日窗口内没有找到足够长的空闲区间。").font(.subheadline) }
                ForEach(Array(result.free_slots.prefix(compact ? 3 : 20).enumerated()), id: \.offset) { _, slot in
                    Label("\(time(slot.start_at)) → \(time(slot.end_at))", systemImage: "clock.badge.checkmark")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                Text("这些是查询时的候选区间，未被预留；是否创建事项请查看实际执行结果。").font(.caption).foregroundStyle(.secondary)
                if result.slots_truncated { Text("仅展示部分候选区间，请缩小范围查看后续。").font(.caption).foregroundStyle(.orange) }
                if !compact {
                    DisclosureGroup("计算依据：\(result.busy_count) 条占用事项") {
                        if result.events.isEmpty { Text("这份历史报告未保存占用明细；需重新查询才能显示依据。").font(.caption) }
                        ForEach(Array(result.events.enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.title).font(.subheadline)
                                Text((event.is_all_day ? "全天 · " : "") + "\(time(event.start_at)) → \(time(event.end_at))").font(.caption)
                                Text("\(event.calendar_name) · \(event.blocks_time ? "计入占用" : "未计入占用")").font(.caption)
                                if let reason = event.occupancy_reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }
                        if result.events_truncated { Text("依据仅展示部分事件；计算使用整个查询范围。").font(.caption) }
                    }
                }
            } else {
                if result.events.isEmpty { Text("该范围内没有查询到事项。").font(.subheadline) }
                ForEach(Array(result.events.prefix(compact ? 3 : 100).enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.title).font(.subheadline.weight(.medium))
                        Text((event.is_all_day ? "全天 · " : "") + "\(time(event.start_at)) → \(time(event.end_at))").font(.caption)
                        Text("\(event.calendar_name) · \(event.blocks_time ? "占用时间" : "不占用时间")").font(.caption).foregroundStyle(.secondary)
                        if let reason = event.occupancy_reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 3)
                }
                if result.events_truncated { Text("共 \(result.event_count) 条，仅展示部分事件。冲突与空闲计算使用了整个查询范围，未按显示条数截断。").font(.caption).foregroundStyle(.orange) }
                else if (compact && result.event_count > 3) || (!compact && result.event_count > 100) { Text("其余事项见详细报告。").font(.caption) }
            }
            if !request.assumptions.isEmpty {
                Text("采用的默认条件").font(.caption.weight(.semibold))
                ForEach(request.assumptions, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            if !compact {
                Text("\(result.calendar_count) 个可访问日历。\(result.scope_note)").font(.caption).foregroundStyle(.secondary)
                Text(sharedForModelAnswer ? "本次查询范围内的标题、时间、日历名称和占用依据会经 Mac 发送给已配置的模型服务，用于回答问题或选择排程时间。" : "历史查询详情仅留在手机，未自动发送给模型。").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func time(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: request.time_zone)
        f.dateFormat = "M月d日 E HH:mm"; return f.string(from: date)
    }
    private func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}
