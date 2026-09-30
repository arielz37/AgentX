import SwiftUI

struct AgentXRootView: View {
    @StateObject private var host: CalendarHost
    @Environment(\.scenePhase) private var phase
    @State private var path: [AssistantModule] = []
    @State private var settings = false
    @State private var catalog = false
    @State private var reportID: String?
    init() {
        #if DEBUG
        let preview = ProcessInfo.processInfo.arguments.contains("--agentx-preview")
        #else
        let preview = false
        #endif
        _host = StateObject(wrappedValue: CalendarHost(preview: preview))
    }
    var body: some View {
        NavigationStack(path: $path) {
            home
                .navigationDestination(for: AssistantModule.self) { module in
                    AssistantChatView(host: host, module: module, openSettings: { settings = true }) { text in
                        host.drafts["auto"] = text
                        path = [.auto]
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32) }
                            .accessibilityLabel("设置与连接")
                    }
                }
        }
        .tint(AssistantModule.auto.color)
        .sheet(isPresented: $settings) { NavigationStack { SettingsView(host: host) } }
        .sheet(isPresented: $catalog) { NavigationStack { CapabilityCatalog() } }
        .sheet(isPresented: Binding(get: { reportID != nil }, set: { if !$0 { reportID = nil } })) {
            NavigationStack {
                if let job = host.jobs.first(where: { $0.id == reportID }) {
                    PlanReportView(job: job, continueAction: { host.continueJob(job.id) })
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { reportID = nil } } }
                }
            }
        }
        .onAppear {
            host.start()
            #if DEBUG
            if host.preview {
                if ProcessInfo.processInfo.arguments.contains("--preview-chat") { path = [.calendar] }
                if ProcessInfo.processInfo.arguments.contains("--preview-catalog") { catalog = true }
                if ProcessInfo.processInfo.arguments.contains("--preview-settings") { settings = true }
                if ProcessInfo.processInfo.arguments.contains("--preview-long") { host.drafts["calendar"] = "下周五上午九点到十点练琴，提前一天和提前两小时提醒。重要时间还没确定的事项请留空，不要替我猜测。" }
            }
            #endif
        }
        .onChange(of: phase) { _, value in host.sceneChanged(value) }
    }
    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkle").foregroundStyle(AssistantModule.auto.color)
                        Text("YOUR PERSONAL SPACE").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                    }
                    Text("AgentX").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("今天，有什么需要帮忙？").font(.title3).foregroundStyle(.secondary)
                }.padding(.top, 10)
                connectionBanner
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("我的助手").font(.headline); Spacer(); Text("2 个已添加").font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 14) {
                        ForEach(AssistantModule.allCases) { module in
                            NavigationLink(value: module) { moduleCard(module) }.buttonStyle(.plain)
                        }
                        Button { catalog = true } label: {
                            VStack(alignment: .leading, spacing: 15) {
                                Image(systemName: "plus").font(.title2).frame(width: 52, height: 52).background(.quaternary, in: RoundedRectangle(cornerRadius: 17))
                                Text("添加助手").font(.headline)
                                Text("发现更多能力").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 147, alignment: .leading).padding(18)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        }.buttonStyle(.plain).accessibilityHint("浏览助手能力目录")
                    }
                }
                recentTasks
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "hand.raised").font(.caption)
                    Text("你继续使用手机，助手在允许的时间内完成任务。结果回来再看。").font(.caption).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(.secondary).padding(.bottom, 14)
            }.padding(.horizontal, 22)
        }.background(Color(uiColor: .systemGroupedBackground)).navigationBarTitleDisplayMode(.inline)
    }
    private func moduleCard(_ module: AssistantModule) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                ModuleIcon(module: module, size: 52)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.medium)).foregroundStyle(module.color.opacity(0.7))
            }
            Text(module.title).font(.headline)
            Text(module.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 147, alignment: .leading).padding(18)
            .background(module.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(module.color.opacity(0.1)))
            .accessibilityElement(children: .combine)
    }
    private var connectionBanner: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            Button { settings = true } label: {
                HStack(spacing: 10) {
                    Circle().fill(host.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(host.preview ? "界面预览 · 不执行任务" : host.connected ? "已连接，随时说出你的计划" : "先连接 Mac，开始使用助手").font(.caption)
                    Spacer()
                    if host.testMode { Text("测试模式").font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule()) }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }.foregroundStyle(.secondary).padding(13).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
            }.buttonStyle(.plain)
        }
    }
    private var recentTasks: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近任务").font(.headline)
            if host.jobs.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.title2).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 5) { Text("从一句话开始").font(.subheadline.weight(.medium)); Text("完成的安排与待确认的信息，都会留在这里。").font(.caption).foregroundStyle(.secondary) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            } else {
                ForEach(Array(host.jobs.prefix(4))) { job in
                    Button { reportID = job.id } label: {
                        HStack(spacing: 12) {
                            ModuleIcon(module: job.module, size: 38)
                            VStack(alignment: .leading, spacing: 5) { Text(job.text).font(.subheadline).lineLimit(2); Text(job.stateTitle).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.foregroundStyle(.primary).padding(15).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct ModuleIcon: View {
    let module: AssistantModule
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: module.icon).font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(module.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.31))
            .accessibilityHidden(true)
    }
}
