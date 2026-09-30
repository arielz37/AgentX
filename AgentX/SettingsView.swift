import SwiftUI

struct SettingsView: View {
    @ObservedObject var host: CalendarHost
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) { ModuleIcon(module: .auto, size: 52); VStack(alignment: .leading, spacing: 5) { Text("AgentX").font(.title2.weight(.semibold)); Text("你的个人助手工作台").font(.caption).foregroundStyle(.secondary) } }.padding(.vertical, 8)
            }
            Section("连接与权限") {
                TimelineView(.periodic(from: .now, by: 2)) { _ in LabeledContent("Mac 连接", value: host.connected ? "已连接" : "等待连接") }
                LabeledContent("日历权限", value: host.authorized ? "完全访问" : "尚未准备")
                Button("准备连接和日历权限") { host.prepare() }.disabled(host.busy || host.preview)
                Text(host.message).font(.caption).foregroundStyle(.secondary)
                Text("先在 Mac 打开 AgentX 的一键启动入口，再保持此 App 在前台完成准备。首次授权需要选择完全访问，以便读回核验。").font(.caption).foregroundStyle(.secondary)
            }
            Section("执行偏好") {
                Toggle("测试模式", isOn: $host.testMode).disabled(host.busy)
                Text("开启后，新增事项带有 AgentX Test 前缀，修改和删除也仅限此前缀事项。").font(.caption).foregroundStyle(.secondary)
            }
            Section("使用边界") {
                Text("可以留在前台等待，单次最长 5 分钟；切回游戏或聊天后，后台窗口最多 45 秒，系统可能提前结束。模型结果会保留，窗口结束后需主动继续才写入。")
                Text("支持查询一个日历年、修改和删除已有事项，以及定时或全天自动排程。重复自动排程暂不支持；重复新建检查一年内各次发生并注明范围。")
                Text("新查询会将本次范围内的事件标题、时间、日历名称、占用依据和空档经 Mac 发送给已配置的模型服务，结合你的问题生成回答。同一助手最近六轮的输入、回答和结果摘要用于理解连续对话；改删还发送目标候选的地点、备注和链接。设备事件标识不交给模型。查询是快照，模型仍可能理解有误。")
                Text("新提交的创建、排程、修改和删除任务，会把本次事项的计划、实际保存/读回状态及失败原因交给模型生成自然语言答复；不为此上传其他日程或重跑操作。旧报告保留原样。")
            }.font(.footnote)
            Section("参与忙闲计算的日历") {
                Text("关闭后仍会展示其中的事项，但不会阻挡空档或触发新建冲突。识别出的只读节假日订阅默认关闭；个人全天安排仍参与计算。更改只影响后续查询，不修改系统日历或旧报告。").font(.caption).foregroundStyle(.secondary)
                ForEach(host.calendarScopes) { scope in
                    Toggle(isOn: Binding(get: { scope.included }, set: { host.setCalendarIncluded(scope.id, included: $0) })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scope.title)
                            Text(scope.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(host.busy || host.preview)
                }
                if host.calendarScopes.isEmpty { Text("完成日历授权后可查看日历来源。").font(.caption) }
                Button("刷新日历列表") { host.refreshCalendarScopes() }.disabled(host.busy || host.preview)
            }
            Section {
                DisclosureGroup("诊断信息") {
                    LabeledContent("手机服务", value: host.ready ? "已启动" : "等待准备")
                    LabeledContent("模型配置", value: host.modelReady ? "Mac 已就绪" : "等待 Mac")
                    LabeledContent("本地任务", value: String(host.jobs.count))
                    Text("查看 AgentX 与 Mac 的连接状态和日历访问权限。").font(.caption)
                }
            }
            if host.preview { Section { Text("界面预览，不连接 Mac、不执行任务。").foregroundStyle(.orange) } }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .onAppear { host.refreshCalendarScopes() }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
struct CapabilityCatalog: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section { VStack(alignment: .leading, spacing: 8) { Text("为你的生活，添一位助手。").font(.title2.weight(.semibold)); Text("专注不同任务，保持熟悉的对话方式。").font(.subheadline).foregroundStyle(.secondary) }.padding(.vertical, 15) }
            Section("已添加") {
                ForEach(AssistantModule.allCases) { module in HStack(spacing: 13) { ModuleIcon(module: module); VStack(alignment: .leading, spacing: 5) { Text(module.title).font(.headline); Text(module.subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }
            }
            Section("正在准备") {
                future("邮件助手", icon: "envelope", description: "邮件相关能力，尚未开放")
                future("短信助手", icon: "message", description: "消息相关能力，尚未开放")
            }
            Section { Text("这里是 AgentX 的能力目录。未开放的助手暂时无法添加或执行任务。").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("添加助手").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
    private func future(_ title: String, icon: String, description: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.title3).frame(width: 44, height: 44).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(description).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Text("即将推出").font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}
