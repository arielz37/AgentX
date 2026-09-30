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
                Text("开启后，新增事项带有 AgentX Test 前缀，方便你在系统日历中区分。").font(.caption).foregroundStyle(.secondary)
            }
            Section("使用边界") {
                Text("可以留在前台等待，也可以切回游戏或聊天。单次任务窗口最多 45 秒，系统可能提前结束后台时间。")
                Text("目前支持新建日程与提醒，不支持修改或删除已有事项。未查询你的日历空闲时间。")
                Text("重要信息不明确时会保留空缺。模型复核仍可能出错；保存成功、读回一致和通知送达是不同的状态。")
            }.font(.footnote)
            Section {
                DisclosureGroup("诊断信息") {
                    LabeledContent("手机服务", value: host.ready ? "已启动" : "等待准备")
                    LabeledContent("模型配置", value: host.modelReady ? "Mac 已就绪" : "等待 Mac")
                    LabeledContent("本地任务", value: String(host.jobs.count))
                    Text("此处只显示 AgentX 的状态。旧版 PhoneAgent 使用独立服务和记录。").font(.caption)
                }
            }
            if host.preview { Section { Text("界面预览，不连接 Mac、不执行任务。").foregroundStyle(.orange) } }
        }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
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
