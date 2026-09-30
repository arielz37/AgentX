import SwiftUI

struct AssistantChatView: View {
    @ObservedObject var host: CalendarHost
    let module: AssistantModule
    let openSettings: () -> Void
    let transferToAuto: (String) -> Void
    @State private var reportID: String?
    @FocusState private var typing: Bool
    private var draft: Binding<String> { Binding(get: { host.drafts[module.id] ?? "" }, set: { host.drafts[module.id] = $0 }) }
    private var jobs: [PlanJob] { host.jobs.filter { $0.scope == module.id }.reversed() }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 25) {
                    if jobs.isEmpty { welcome }
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 17) {
                            HStack { Spacer(minLength: 35); Text(job.text).font(.body).padding(16).background(module.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 22)).textSelection(.enabled) }
                            HStack(spacing: 8) { ModuleIcon(module: module, size: 25); Text(module.title).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                            TaskCard(job: job, transfer: { transferToAuto(job.text) }, report: { reportID = job.id }, resume: { host.continueJob(job.id) }, retryAnswer: { host.retryAnswer(job.id) })
                        }.id(job.id)
                    }
                    Color.clear.frame(height: 2).id("bottom")
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) { composer { withAnimation { reader.scrollTo("bottom", anchor: .bottom) } } }
        }
        .onAppear {
            #if DEBUG
            if host.preview && ProcessInfo.processInfo.arguments.contains("--preview-keyboard") { typing = true }
            #endif
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(module.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("连接与设置") } }
        .sheet(isPresented: Binding(get: { reportID != nil }, set: { if !$0 { reportID = nil } })) {
            NavigationStack {
                if let job = host.jobs.first(where: { $0.id == reportID }) {
                    PlanReportView(job: job, continueAction: { host.continueJob(job.id) })
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { reportID = nil } } }
                }
            }
        }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            ModuleIcon(module: module, size: 66).padding(.top, 36)
            Text(module.welcome).font(.system(.title2, design: .rounded, weight: .semibold)).lineSpacing(5)
            Text(module.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("试着这样说").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(module.examples, id: \.self) { example in
                    Button { draft.wrappedValue = example } label: {
                        HStack(alignment: .top, spacing: 12) { Text(example).font(.subheadline).multilineTextAlignment(.leading); Spacer(minLength: 4); Image(systemName: "arrow.up.left").font(.caption) }
                            .foregroundStyle(.primary).padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
                    }.buttonStyle(.plain).accessibilityHint("填入输入框，不自动发送")
                }
            }.padding(.top, 8)
            if host.preview { Text("界面预览 · 示例不会执行").font(.caption).foregroundStyle(.orange) }
        }.padding(.bottom, 20)
    }
    private func composer(didSubmit: @escaping () -> Void) -> some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(spacing: 10) {
                if !host.connected && !host.preview {
                    Button(action: openSettings) { Label("连接 Mac 后即可发送", systemImage: "link").font(.caption) }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField(module == .auto ? "说说你想做什么…" : "说说你的安排…", text: draft, axis: .vertical)
                        .lineLimit(1...6).padding(.vertical, 13).padding(.leading, 16).focused($typing)
                        .accessibilityLabel("输入需求")
                    Button {
                        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if host.submit(text, assistant: module.id) { draft.wrappedValue = ""; typing = false; didSubmit() }
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(host.canSubmit(draft.wrappedValue) ? module.color : Color.gray.opacity(0.45), in: Circle())
                    }.disabled(!host.canSubmit(draft.wrappedValue)).accessibilityLabel("发送需求").padding(6)
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 25))
                    .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(.quaternary))
                HStack(spacing: 5) {
                    if host.testMode { Image(systemName: "flask"); Text("测试模式 · ") }
                    Text(host.busy ? "任务处理中，完成后可再次提交" : "接口数据及最近6轮对话用于理解需求")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8).background(.regularMaterial)
        }
    }
}

struct TaskCard: View {
    let job: PlanJob
    let transfer: () -> Void
    let report: () -> Void
    let resume: () -> Void
    let retryAnswer: () -> Void
    private var color: Color { ["verified", "query_complete"].contains(job.state) ? .green : job.running ? job.module.color : .orange }
    var body: some View {
        if job.completion_source_id != nil {
            VStack(alignment: .leading, spacing: 15) {
                if let answer = job.answer {
                    Text(answer.text).font(.body).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if job.completion_answer_state == "failed" {
                    Text("日历处理结果已保留 · 答复暂未生成").font(.headline)
                    Text(job.message).font(.subheadline)
                    Text(job.completion_answer_error ?? "实际执行记录已保存，模型回答暂未生成，可查看详情。")
                        .font(.body).foregroundStyle(.secondary)
                    if job.canRetryAnswer { Button("重新生成答复", action: retryAnswer).buttonStyle(.borderedProminent) }
                } else {
                    Text(job.message).font(.subheadline).foregroundStyle(.secondary)
                    ProgressView("正在根据实际结果回复你…")
                }
                Button("查看执行依据与详情", action: report).font(.caption.weight(.medium))
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        } else if job.queryResult != nil && job.route?.kind != "calendar_schedule" {
            VStack(alignment: .leading, spacing: 15) {
                if let answer = job.answer {
                    Text(answer.text).font(.body).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("模型依据本次日历查询数据回答 · 未新增事项").font(.caption).foregroundStyle(.secondary)
                    if job.queryResult?.events_truncated == true || job.queryResult?.slots_truncated == true {
                        Label("接口明细不完整，范围限制见查询依据", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    if job.state == "answer_pending" { ProgressView("数据已读取，等待模型回答") }
                    Text(job.version < 5 ? "这是一份历史查询记录，未发送给模型生成回答。" : job.message).font(.body)
                    if job.canRetryAnswer { Button("重新生成答复", action: retryAnswer).buttonStyle(.borderedProminent) }
                }
                Button("查看依据与完整结果", action: report).font(.caption.weight(.medium))
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        } else {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                if job.running { ProgressView().tint(job.module.color) }
                else { Image(systemName: ["verified", "query_complete"].contains(job.state) ? "checkmark.circle.fill" : "info.circle.fill").foregroundStyle(color) }
                Text(job.stateTitle).font(.headline)
                Spacer()
            }
            if ["calendar", "calendar_schedule", "calendar_mutation"].contains(job.route?.kind ?? "") { Label("使用日程助手处理", systemImage: "calendar").font(.caption).foregroundStyle(AssistantModule.calendar.color) }
            if let mutation = job.mutation { Text(mutation.message).font(.body).textSelection(.enabled) }
            if let schedule = job.schedule { Text(schedule.message).font(.body).textSelection(.enabled) }
            Text(job.message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let route = job.route, !route.unsupported.isEmpty {
                Text("暂不支持：" + route.unsupported.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                if route.kind == "mixed" { Text("这次没有创建日程，请将可执行的日程需求单独提交。").font(.caption) }
            }
            if let review = job.review_status { Text(review == "corrected" ? "模型已复核并修正候选计划" : "模型已复核 · 执行结果以下方为准").font(.caption).foregroundStyle(.secondary) }
            if job.resultData != nil && job.mutation == nil && (job.query == nil || job.schedule != nil) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 22) { metrics }
                    VStack(alignment: .leading, spacing: 12) { metrics }
                }
            }
            if let items = job.plan?.items {
                let defaults = items.flatMap { $0.fields.values }.filter { $0.source == "defaulted" }.count
                let missing = items.flatMap { $0.fields.values }.filter { $0.source == "unresolved" }.count
                HStack(spacing: 12) { Label("\(defaults) 处自动补齐", systemImage: "sparkle"); Label("\(missing) 处空缺", systemImage: "questionmark.circle") }.font(.caption).foregroundStyle(.secondary)
            }
            if job.state == "scope_mismatch" {
                Button("转到全能助手", action: transfer).font(.subheadline.weight(.semibold))
                Text("保留这段输入，由你决定是否发送。").font(.caption).foregroundStyle(.secondary)
            }
            if job.state == "window_expired", (job.plan != nil || job.query != nil) { Button("继续执行这份计划", action: resume).buttonStyle(.borderedProminent) }
            if job.plan != nil || job.query != nil || job.resultData != nil { Button(action: report) { HStack { Text("查看详细报告"); Spacer(); Image(systemName: "arrow.right") }.font(.subheadline.weight(.medium)) } }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }
    }
    @ViewBuilder private var metrics: some View {
        metric("保存并验证", value: job.verifiedCount)
        metric("已保存", value: job.savedCount)
        metric("未验证完成", value: max(0, (job.plan?.items.count ?? 0) - job.verifiedCount))
    }
    private func metric(_ title: String, value: Int) -> some View { VStack(alignment: .leading, spacing: 3) { Text("\(value)").font(.title2.weight(.semibold)); Text(title).font(.caption2).foregroundStyle(.secondary) } }
}
