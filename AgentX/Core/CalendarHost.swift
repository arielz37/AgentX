import SwiftUI
import UIKit

@MainActor
final class CalendarHost: ObservableObject {
    @Published var message = "请连接 Mac worker，并准备日历权限"
    @Published var ready = false
    @Published var authorized = false
    @Published var modelReady = false
    @Published var jobs: [PlanJob] = []
    let preview: Bool
    @Published var drafts: [String: String] = [:]
    @Published var testMode = true
    @Published var calendarScopes: [CalendarScopeOption] = []
    private let storage: PlanStore
    private let calendar: CalendarBridge
    private let mutator: CalendarMutator
    private var server: SimulatorRPCServer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var deadline: Date?
    private var sessionWindow: CalendarSessionWindow?
    private var timer: Timer?
    private var heartbeat: Date = .distantPast
    private var activeID: String?
    private var storageFailed = false
    private var lease: String = ""

    init(preview: Bool = false) {
        self.preview = preview
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(preview ? "AgentXPreview" : "AgentX")
        storage = PlanStore(directory: directory)
        calendar = CalendarBridge(executionLocation: "iphone_native_app", ledgerURL: directory.appendingPathComponent("ledger.json"))
        mutator = CalendarMutator(ledgerURL: directory.appendingPathComponent("mutation-ledger.json"))
        if preview { message = "界面预览，不执行任务"; return }
        do {
            jobs = try storage.load()
            for i in jobs.indices where ["queued", "parsing", "planned", "executing"].contains(jobs[i].state) {
                let unknown = jobs[i].state == "executing"
                jobs[i].state = unknown ? "unknown" : "window_expired"
                jobs[i].message = unknown ? "执行期间进程结束，结果未知；请手动核验，不要重新提交" : "上次执行窗口已结束，没有自动重放"
            }
            try storage.save(jobs)
        } catch { storageFailed = true; message = "本地记录无法读取，已禁用写入，请保留数据排查" }
        calendar.mayWrite = { [weak self] in self?.canWrite ?? false }
        mutator.mayWrite = { [weak self] in self?.canWrite ?? false }
    }
    private func error(_ text: String) -> NSError { NSError(domain: "AgentX.Host", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private var canWrite: Bool {
        let state = UIApplication.shared.applicationState
        return CalendarExecutionPolicy.allows(foreground: state == .active, background: state == .background,
            sessionActive: activeID != nil, storageHealthy: !storageFailed,
            windowRemaining: deadline?.timeIntervalSinceNow ?? 0,
            hasBackgroundAssertion: backgroundTask != .invalid,
            backgroundRemaining: UIApplication.shared.backgroundTimeRemaining)
    }
    var busy: Bool { activeID != nil }
    var connected: Bool { ready && modelReady && Date().timeIntervalSince(heartbeat) < 5 }
    func canSubmit(_ text: String) -> Bool { !preview && connected && !busy && !storageFailed && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 4000 }
    private func persist() throws {
        do { try storage.save(jobs) }
        catch { storageFailed = true; message = "手机记录保存失败，停止后续写入"; throw error }
    }
    func start() {
        guard !preview, server == nil, UIApplication.shared.applicationState == .active else { return }
        do {
            server = try SimulatorRPCServer(onReady: { _ in Task { @MainActor in self.ready = true } }, onStop: {
                Task { @MainActor in self.endWindow("连接已停止"); self.server = nil; self.ready = false }
            }, commandHandler: { [weak self] method, params in
                guard let self else { throw NSError(domain: "AgentX.Host", code: 1) }
                guard params["client"] as? String == AppConfiguration.appID, params["protocol_version"] as? Int == AppConfiguration.protocolVersion else { throw NSError(domain: "AgentX.Protocol", code: 1, userInfo: [NSLocalizedDescriptionKey: "AgentX client identity required"]) }
                let response = try await self.handle(method, params)
                var result = response.result as? [String: Any] ?? [:]
                result["app_id"] = AppConfiguration.appID; result["protocol_version"] = AppConfiguration.protocolVersion
                return (result, response.shouldStop)
            })
            server?.start()
            Task { await refreshAuthorization() }
        } catch { message = error.localizedDescription }
    }
    private func refreshAuthorization() async {
        let status = try? await calendar.handle("calendar_status", [:])
        authorized = status?["authorization"] as? String == "full_access"
        if authorized { _ = try? await calendar.handle("calendar_lock", [:]) }
        refreshCalendarScopes()
    }
    func refreshCalendarScopes() {
        guard !preview, !busy, UIApplication.shared.applicationState == .active else { return }
        calendarScopes = authorized ? CalendarReader().calendarOptions() : []
    }
    func setCalendarIncluded(_ id: String, included: Bool) {
        guard !preview, !busy, calendarScopes.contains(where: { $0.id == id }) else { return }
        CalendarOccupancyPolicy.set(id, included: included, preferences: .standard)
        refreshCalendarScopes()
    }
    func prepare() {
        guard !preview, UIApplication.shared.applicationState == .active, !busy else { return }
        start()
        Task {
            do {
                if !calendar.isLocked { _ = try await calendar.handle("calendar_prepare", ["allow_permission_prompt": true]) }
                await refreshAuthorization()
                message = authorized ? "权限已准备；等 Mac worker 连接后即可执行" : "需要完全日历访问权限，才能保存并独立读回验证"
            } catch { message = error.localizedDescription }
        }
    }
    private func openWindow(id: String) throws {
        guard UIApplication.shared.applicationState == .active, !busy else { throw error("只能由用户在前台开启一次窗口") }
        lease = UUID().uuidString
        let expectedLease = lease
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AgentX pending plan") { [weak self] in
            Task { @MainActor in
                guard let self, self.lease == expectedLease else { return }
                if UIApplication.shared.applicationState == .active {
                    if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
                } else { self.endWindow("系统后台窗口已结束，未执行项没有自动重试") }
            }
        }
        // Foreground work does not require an OS background assertion.
        activeID = id; sessionWindow = CalendarSessionWindow(now: Date())
        scheduleWindowTimer()
    }
    private func scheduleWindowTimer() {
        guard let window = sessionWindow else { return }
        deadline = window.deadline
        timer?.invalidate()
        let expectedLease = lease
        timer = Timer.scheduledTimer(withTimeInterval: max(0.01, window.deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lease == expectedLease, let deadline = self.deadline, deadline <= Date() else { return }
                self.endWindow("本次执行窗口已结束；模型结果会保留，未执行项需主动继续")
            }
        }
    }
    @discardableResult func submit(_ text: String, assistant: String) -> Bool {
        guard canSubmit(text), ["auto", "calendar"].contains(assistant) else { message = "请检查连接；输入上限 4000 字"; return false }
        do {
            let id = "ax-" + UUID().uuidString
            try openWindow(id: id)
            jobs.insert(PlanJob(submission_id: id, task_id: id, version: 8, text: text,
                submitted_at: ISO8601DateFormatter().string(from: Date()), time_zone: TimeZone.current.identifier,
                test_mode: testMode, state: "queued", message: "已保存在手机，等待 Mac 接收", lease_id: lease,
                assistant_id: assistant, conversation_context: Array(jobs.filter { $0.scope == assistant }.prefix(6).reversed()).map(\.conversationTurn),
                conversation_lookups: jobs.filter { $0.scope == assistant }.prefix(6).flatMap(\.conversationLookups)), at: 0)
            try persist(); message = "已提交，可以留在这里或切回其他 App。"
            return true
        } catch { message = error.localizedDescription; endWindow(message); return false }
    }
    func continueJob(_ id: String) {
        guard ready, authorized, modelReady, Date().timeIntervalSince(heartbeat) < 5, !storageFailed,
              let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == "window_expired", (jobs[i].plan != nil || jobs[i].query != nil) else { return }
        do {
            try openWindow(id: id)
            jobs[i].lease_id = lease; jobs[i].state = "planned"; jobs[i].message = "用户主动继续同一计划；可留在此页或切回游戏"
            try persist(); message = jobs[i].message
        } catch { endWindow(error.localizedDescription) }
    }
    func retryAnswer(_ id: String) {
        guard !storageFailed, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let previous = jobs[i]
        do {
            try jobs[i].retryAnswer()
            try persist()
            message = "已请求重新生成答复；只使用已有结果，不重复执行日历操作。"
        } catch { jobs[i] = previous; message = error.localizedDescription }
    }
    func sceneChanged(_ phase: ScenePhase) {
        // Keep the same task and lease across foreground/background transitions.
        // An expired lease remains expired; returning here never rearms old tasks.
        if !preview && phase == .active { start(); Task { await refreshAuthorization() } }
        if phase != .inactive, var window = sessionWindow, activeID != nil {
            guard window.transition(foreground: phase == .active, now: Date()) else {
                endWindow("执行窗口已结束；未自动重新开启")
                return
            }
            sessionWindow = window; scheduleWindowTimer()
        }
    }
    private func endWindow(_ text: String) {
        if let id = activeID, let i = jobs.firstIndex(where: { $0.id == id }), ["queued", "parsing", "planned"].contains(jobs[i].state) {
            jobs[i].state = "window_expired"; jobs[i].message = "任务未执行：\(text)"; try? persist()
        }
        if let id = activeID, let i = jobs.firstIndex(where: { $0.id == id }), ["answer_pending", "schedule_pending", "mutation_pending"].contains(jobs[i].state) {
            jobs[i].message = ["calendar_schedule", "calendar_mutation"].contains(jobs[i].route?.kind ?? "") ? "日历已读取，等待模型决策；窗口结束后只保存计划，需主动继续才写入。" : "日历已读取，正在等待模型回答；若后台连接暂停，回来后同步回答，不重新读取日历。"; try? persist()
        }
        activeID = nil; deadline = nil; sessionWindow = nil; timer?.invalidate(); timer = nil
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        message = text
    }
    private func hostStatus() -> [String: Any] {
        let budget = UIApplication.shared.backgroundTimeRemaining
        return ["application_state": UIApplication.shared.applicationState == .background ? "background" : (UIApplication.shared.applicationState == .active ? "foreground" : "inactive"),
                "background_budget_seconds": budget < 1e9 ? budget : -1,
                "window_remaining_seconds": max(0, deadline?.timeIntervalSinceNow ?? 0), "can_execute": canWrite,
                "import_armed": busy]
    }
    private func decodeRoute(_ params: [String: Any], job: PlanJob, hasPlan: Bool, hasQuery: Bool = false) throws -> ModuleRoute {
        guard let raw = params["route"] as? [String: Any], let review = params["review_status"] as? String else { throw error("缺少能力路由或复核结果") }
        let data = try JSONSerialization.data(withJSONObject: raw)
        let route = try JSONDecoder().decode(ModuleRoute.self, from: data)
        try AgentXRouting.validate(route, hasPlan: hasPlan, hasQuery: hasQuery, review: review, scope: job.scope)
        return route
    }
    private func index(_ p: [String: Any]) throws -> Int {
        guard let id = p["submission_id"] as? String, let i = jobs.firstIndex(where: { $0.id == id }),
              p["task_id"] as? String == jobs[i].task_id, p["version"] as? Int == jobs[i].version, p["assistant_id"] as? String == jobs[i].scope else { throw error("任务或版本不匹配") }
        return i
    }
    private func handle(_ method: String, _ p: [String: Any]) async throws -> (result: Any, shouldStop: Bool) {
        if method == "stop" { return ([:], true) }
        if method == "calendar_status" {
            var result = try await calendar.handle(method, p); result["host"] = hostStatus(); return (result, false)
        }
        if method == "plan_poll" {
            heartbeat = Date(); modelReady = p["model_ready"] as? Bool == true
            return (["jobs": jobs.map(\.wire), "host": hostStatus(), "authorized": authorized], false)
        }
        if method == "plan_heartbeat" {
            let i = try index(p)
            heartbeat = Date(); modelReady = p["model_ready"] as? Bool == true
            let phases = ["parse": "正在理解并复核计划", "schedule": "已读取日历，正在选时并复核", "mutation": "已读取候选，正在核对修改方案", "answer": "已读取日历，正在生成回答"]
            if ["parsing", "schedule_pending", "mutation_pending", "answer_pending"].contains(jobs[i].state),
               activeID == jobs[i].id, let phase = p["phase"] as? String, let label = phases[phase] {
                jobs[i].message = label + "；复杂任务可能需要更长时间，请勿重复提交"
            }
            return (["host": hostStatus()], false)
        }
        guard method.hasPrefix("plan_") else { throw error("本宿主只允许计划处理，不提供 UI 自动化或远程授权") }
        let i = try index(p)
        if ["plan_completion_store", "plan_completion_fail", "plan_answer_store", "plan_answer_fail"].contains(method) {
            try jobs[i].validateAnswerAttempt(p["answer_retry_id"] as? String)
        }
        switch method {
        case "plan_completion_context":
            return (try jobs[i].completionContext(), false)
        case "plan_completion_store":
            guard !storageFailed, let raw = p["answer"] as? [String: Any] else { throw error("缺少模型回答或存储不可用") }
            let answer = try JSONDecoder().decode(ModelAnswer.self, from: JSONSerialization.data(withJSONObject: raw))
            try jobs[i].acceptCompletionAnswer(answer); try persist()
        case "plan_completion_fail":
            guard jobs[i].version >= 8, jobs[i].completion_source_id == p["source_id"] as? String,
                  jobs[i].completion_source_id != nil else { throw error("回答失败状态与执行记录不匹配") }
            if jobs[i].answer != nil { return (jobs[i].wire, false) }
            guard ["pending", "failed"].contains(jobs[i].completion_answer_state ?? "") else { throw error("不在等待回答状态") }
            jobs[i].completion_answer_state = "failed"
            jobs[i].completion_answer_error = p["message"] as? String ?? "执行记录已保存，但模型回答未生成；可查看详情。"
            try persist()
        case "plan_mutation_context":
            guard let snapshot = jobs[i].mutationSnapshot else { throw error("没有已读取的修改候选") }
            return (snapshot.context, false)
        case "plan_mutation_store":
            guard !storageFailed, let raw = p["mutation"] as? [String: Any] else { throw error("缺少修改决策") }
            let decision = try JSONDecoder().decode(MutationDecision.self, from: JSONSerialization.data(withJSONObject: raw))
            try jobs[i].acceptMutation(decision, windowActive: activeID == jobs[i].id && canWrite); try persist()
            if decision.decision != "execute" { finishAfterResponse(jobs[i].id, message: jobs[i].message) }
        case "plan_mutation_fail":
            guard jobs[i].mutation == nil, jobs[i].mutationSnapshot?.source_id == p["source_id"] as? String, ["mutation_pending", "mutation_failed"].contains(jobs[i].state) else { throw error("修改决策状态不匹配") }
            jobs[i].state = "mutation_failed"; jobs[i].message = p["message"] as? String ?? "已读取候选，但模型决策未通过；没有修改/删除事件。"; try persist(); finishAfterResponse(jobs[i].id, message: jobs[i].message)
        case "plan_schedule_store":
            guard !storageFailed, let raw = p["schedule"] as? [String: Any] else { throw error("缺少排程决策") }
            let value = try JSONDecoder().decode(ScheduleDecision.self, from: JSONSerialization.data(withJSONObject: raw))
            try jobs[i].acceptSchedule(value, windowActive: activeID == jobs[i].id && canWrite)
            try persist()
            if jobs[i].plan == nil { finishAfterResponse(jobs[i].id, message: jobs[i].message) }
        case "plan_schedule_fail":
            guard jobs[i].version >= 6, jobs[i].route?.kind == "calendar_schedule", jobs[i].query_result_id == p["source_id"] as? String,
                  jobs[i].schedule == nil, ["schedule_pending", "schedule_failed"].contains(jobs[i].state) else { throw error("排程失败状态不匹配") }
            jobs[i].state = "schedule_failed"; jobs[i].message = p["message"] as? String ?? "已读取空档，但模型排程未通过；没有创建事项。详情保留在 Mac。"
            try persist(); finishAfterResponse(jobs[i].id, message: jobs[i].message)
        case "plan_answer_context":
            return (try jobs[i].answerContext(), false)
        case "plan_answer_store":
            guard !storageFailed, let raw = p["answer"] as? [String: Any] else { throw error("缺少模型回答或存储不可用") }
            let answer = try JSONDecoder().decode(ModelAnswer.self, from: JSONSerialization.data(withJSONObject: raw))
            try jobs[i].acceptAnswer(answer); try persist()
            finishAfterResponse(jobs[i].id, message: jobs[i].message)
        case "plan_answer_fail":
            guard jobs[i].version >= 5, jobs[i].queryResult != nil, p["source_id"] as? String == jobs[i].query_result_id else { throw error("回答失败状态与查询不匹配") }
            if jobs[i].answer != nil { return (jobs[i].wire, false) }
            guard ["answer_pending", "answer_failed"].contains(jobs[i].state) else { throw error("任务状态不允许更改") }
            jobs[i].state = "answer_failed"
            jobs[i].message = p["message"] as? String ?? "日历已读取，但模型回答未完成。可查看原始结果；没有重新执行日历操作。"
            try persist(); finishAfterResponse(jobs[i].id, message: jobs[i].message)
        case "plan_claim":
            if jobs[i].state == "queued" { jobs[i].state = "parsing"; jobs[i].message = "Mac 已接收，正在理解；可以切回游戏"; try persist(); message = jobs[i].message }
        case "plan_fail":
            guard jobs[i].plan == nil, jobs[i].query == nil, jobs[i].resultData == nil else { throw error("不能覆盖已有计划或结果") }
            jobs[i].state = "failed"; jobs[i].message = p["message"] as? String ?? "模型失败"; try persist()
            if activeID == jobs[i].id { endWindow(jobs[i].message) }
        case "plan_route":
            guard jobs[i].plan == nil, jobs[i].query == nil, jobs[i].resultData == nil, ["queued", "parsing", "window_expired"].contains(jobs[i].state) else { throw error("任务已结束") }
            let route = try decodeRoute(p, job: jobs[i], hasPlan: false)
            jobs[i].route = route; jobs[i].review_status = p["review_status"] as? String
            jobs[i].state = AgentXRouting.terminalState(route.kind, scope: jobs[i].scope)
            jobs[i].message = route.message; try persist()
            if activeID == jobs[i].id { endWindow(route.message) }
        case "plan_store":
            if let raw = p["query"] as? [String: Any] {
                guard jobs[i].version >= 4, jobs[i].plan == nil, p["plan"] == nil || p["plan"] is NSNull else { throw error("不能混合查询与创建计划") }
                let route = try decodeRoute(p, job: jobs[i], hasPlan: false, hasQuery: true)
                let query = try JSONDecoder().decode(CalendarQuery.self, from: JSONSerialization.data(withJSONObject: raw))
                _ = try query.bounds()
                if route.kind == "calendar_mutation" { guard jobs[i].version >= 7, query.mode == "events" else { throw error("修改需要新版候选查询") } }
                let refs = query.target_history_refs ?? []
                let known = Set((jobs[i].conversation_context ?? []).flatMap(\.events).compactMap(\.history_ref))
                guard refs.count <= 8, Set(refs).count == refs.count, Set(refs).isSubset(of: known), refs.isEmpty || route.kind == "calendar_mutation" else { throw error("历史目标引用与当前对话不匹配") }
                var manifest: ScheduleRequest?
                if route.kind == "calendar_schedule" {
                    guard jobs[i].version >= 6, query.mode == "free_slots", (query.slot_kind == "all_day" || query.duration_minutes <= 180),
                          let request = p["schedule_request"] as? [String: Any] else { throw error("自动排程需要新版清单及空档查询，时长不超过3小时") }
                    manifest = try JSONDecoder().decode(ScheduleRequest.self, from: JSONSerialization.data(withJSONObject: request))
                    try manifest!.validate(text: jobs[i].text)
                    if let old = jobs[i].schedule_request, old != manifest { throw error("不可变排程清单冲突") }
                }
                if let old = jobs[i].query { guard old == query else { throw error("query_conflict: 已有不同的不可变查询") } }
                else {
                    guard ["parsing", "queued", "window_expired"].contains(jobs[i].state) else { throw error("任务已结束") }
                    jobs[i].query = query; jobs[i].schedule_request = manifest; jobs[i].route = route; jobs[i].review_status = p["review_status"] as? String
                    jobs[i].state = activeID == jobs[i].id ? "planned" : "window_expired"
                    jobs[i].message = activeID == jobs[i].id ? "查询范围已确定，准备在手机读取" : "查询尚未执行：执行窗口已结束"
                    try persist()
                }
                return (jobs[i].wire, false)
            }
            guard jobs[i].query == nil else { throw error("不能覆盖已有查询") }
            let route = try decodeRoute(p, job: jobs[i], hasPlan: true)

            guard let raw = p["plan"] as? [String: Any] else { throw error("缺少计划") }
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            let plan = try JSONDecoder().decode(CalendarPlan.self, from: data); try plan.validate(text: jobs[i].text)
            if jobs[i].version >= 2 && plan.items.contains(where: { $0.alerts == nil }) { throw error("新版计划缺少提醒契约") }
            if jobs[i].version < 2 && plan.items.contains(where: { $0.alerts != nil }) { throw error("历史计划不能添加新提醒") }
            if jobs[i].version >= 3 && plan.items.contains(where: { $0.calendar == nil }) { throw error("新版计划缺少日历能力契约，请更新 Mac worker") }
            if jobs[i].version < 3 && plan.items.contains(where: { $0.calendar != nil }) { throw error("历史计划不能添加重复或其他新能力") }
            if let old = jobs[i].planData { guard try AlertPolicy.canonicalPlan(AlertPolicy.object(old)) == AlertPolicy.canonicalPlan(raw) else { throw error("plan_conflict: 不可变计划已有不同内容") } }
            else {
                guard ["parsing", "queued", "window_expired"].contains(jobs[i].state) else { throw error("任务已结束，拒绝旧模型结果") }
                jobs[i].plan = plan; jobs[i].planData = data
                jobs[i].route = route; jobs[i].review_status = p["review_status"] as? String
                if activeID == jobs[i].id { jobs[i].state = "planned"; jobs[i].message = "计划已生成，准备在手机执行" }
                else { jobs[i].state = "window_expired"; jobs[i].message = "计划已生成，日历未执行：后台窗口已结束" }
                try persist()
            }
        case "plan_execute":
            // Same lease replay returns the stored report. No new side effect.
            let mutating = jobs[i].route?.kind == "calendar_mutation"
            let mutationWrite = mutating && jobs[i].mutation?.decision == "execute"
            let scheduling = jobs[i].route?.kind == "calendar_schedule"
            let scheduleWrite = scheduling && jobs[i].schedule?.decision == "scheduled"
            if jobs[i].resultData != nil && !((scheduleWrite || mutationWrite) && jobs[i].state == "planned") { return (jobs[i].wire, false) }
            guard jobs[i].state == "planned", jobs[i].id == activeID, p["lease_id"] as? String == lease,
                  (jobs[i].plan != nil || jobs[i].query != nil) else { throw error("未执行：计划状态或窗口不匹配；没有自动重放") }
            if UIApplication.shared.applicationState == .inactive && (deadline?.timeIntervalSinceNow ?? 0) > 5 && !storageFailed {
                // No reservation or EventKit call happened. The worker may wait for an
                // eligible state and send the SAME lease; lost responses remain unknown.
                var deferred = jobs[i].wire
                deferred["execution_deferred"] = true
                deferred["deferred_reason"] = "application_transition_no_writes"
                return (deferred, false)
            }
            guard authorized else { throw error("日历尚未授权，请在设置中准备权限后再提交") }
            guard let route = jobs[i].route, let review = jobs[i].review_status else { throw error("缺少能力路由或复核结果") }
            try AgentXRouting.validate(route, hasPlan: jobs[i].plan != nil, hasQuery: jobs[i].query != nil, review: review, scope: jobs[i].scope)
            guard canWrite else { throw error("未执行：执行窗口或后台预算不足；没有自动重放") }
            if mutationWrite, let decision = jobs[i].mutation, let source = jobs[i].mutationSnapshot {
                jobs[i].state = "executing"; jobs[i].message = "正在核对最新事件并修改/删除、读回验证"; try persist()
                var result = try mutator.execute(taskID: jobs[i].task_id, decision: decision, source: source, testMode: jobs[i].test_mode)
                result["host"] = hostStatus(); jobs[i].resultData = try JSONSerialization.data(withJSONObject: result)
                jobs[i].state = result["status"] as? String ?? "unknown"
                jobs[i].message = "修改/删除执行结果：" + jobs[i].state + "；详情见逐项真实记录"
                jobs[i].prepareCompletionAnswer()
                try persist(); finishAfterResponse(jobs[i].id, message: jobs[i].message)
                var response = jobs[i].wire
                if jobs[i].completion_source_id != nil { response["completion_context"] = try jobs[i].completionContext() }
                return (response, false)
            }
            if mutating, let query = jobs[i].query {
                jobs[i].state = "executing"; try persist()
                do {
                    let snapshot = try mutator.read(query, history: (jobs[i].conversation_lookups ?? []).filter { (query.target_history_refs ?? []).contains($0.history_ref) }); jobs[i].mutationSnapshot = snapshot
                    jobs[i].resultData = try JSONSerialization.data(withJSONObject: ["operation": "mutation_read", "status": "read_complete", "candidate_count": snapshot.candidates.count, "items": []])
                    jobs[i].state = "mutation_pending"; jobs[i].message = "已读取真实事件，模型正在结合上下文确定修改目标"
                    try persist(); var response = jobs[i].wire; response["mutation_context"] = snapshot.context; return (response, false)
                } catch { jobs[i].state = "failed"; jobs[i].message = "读取修改候选失败：" + error.localizedDescription; try persist(); finishAfterResponse(jobs[i].id, message: jobs[i].message); return (jobs[i].wire, false) }
            }
            if let query = jobs[i].query, !scheduleWrite {
                jobs[i].state = "executing"; jobs[i].message = jobs[i].version >= 5 ? "正在读取日历，随后将查询数据交给模型回答" : "正在手机读取日历"; try persist()
                do {
                    let result = try CalendarReader().query(query, detailLimit: jobs[i].version >= 7 ? 2000 : 100, slotLimit: jobs[i].version >= 7 ? 2000 : 20)
                    jobs[i].queryResult = result
                    var summary = result.publicSummary; summary["host"] = hostStatus()
                    if jobs[i].version >= 5 { summary["privacy"] = "query_details_shared_for_model_answer" }
                    jobs[i].resultData = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                    jobs[i].state = "query_complete"
                    switch query.mode {
                    case "free_slots": jobs[i].message = "找到 \(result.free_slots.count) 个符合条件的空闲区间；仅为查询时快照，未创建日程。"
                    case "conflicts": jobs[i].message = result.busy_count == 0 ? "查询时该区间没有日历占用；未创建日程。" : "查询区间有 \(result.busy_count) 条占用事项；未创建日程。"
                    default: jobs[i].message = "查询到 \(result.event_count) 条日历事项；详情仅保存在手机。"
                    }
                    if jobs[i].version >= 5 {
                        jobs[i].query_result_id = UUID().uuidString
                        jobs[i].state = scheduling ? "schedule_pending" : "answer_pending"; jobs[i].message = scheduling ? "已读取真实空档，模型正在选择合适时间。" : "日历已读取，大模型正在结合你的问题回答。"
                    }
                } catch {
                    jobs[i].state = "failed"; jobs[i].message = "查询失败：" + error.localizedDescription
                }
                try persist()
                if ["answer_pending", "schedule_pending", "mutation_pending"].contains(jobs[i].state) {
                    // Carry the durable snapshot in this response, before background suspension.
                    var response = jobs[i].wire; response["answer_context"] = try jobs[i].answerContext()
                    return (response, false)
                }
                finishAfterResponse(jobs[i].id, message: jobs[i].message)
                return (jobs[i].wire, false)
            }
            guard let plan = jobs[i].plan else { throw error("缺少创建计划") }
            if scheduling {
                guard let decision = jobs[i].schedule else { throw error("尚未依据空档形成排程") }
                try decision.validate(job: jobs[i])
            }
            calendar.checkConflicts = jobs[i].version >= 4
            calendar.comprehensiveConflicts = jobs[i].version >= 7
            jobs[i].state = "executing"; jobs[i].message = jobs[i].version >= 4 ? "正在检查冲突、保存和读回" : "正在手机保存和读回"; try persist()
            let host = hostStatus()
            let executable = plan.items.filter { !$0.blocked && $0.policyIssue(in: plan.items) == nil }.map { $0.event(testMode: jobs[i].test_mode) }
            var result: [String: Any]
            if executable.isEmpty {
                result = ["status": "not_created", "items": [], "execution_location": "iphone_native_app"]
            } else {
                let status = try await calendar.handle("calendar_status", [:])
                result = try await calendar.handle("calendar_execute", ["session_id": status["session_id"]!, "task_id": jobs[i].task_id, "test_mode": jobs[i].test_mode, "items": executable])
            }
            var rows = result["items"] as? [[String: Any]] ?? []
            rows += plan.items.filter(\.blocked).map { ["item_id": $0.item_id, "status": "not_created_missing_information", "save_status": "not_attempted", "verification_status": "not_attempted"] }
            rows += plan.items.compactMap { item -> [String: Any]? in
                guard let issue = item.policyIssue(in: plan.items) else { return nil }
                return ["item_id": item.id, "status": "not_created_policy_rejected", "save_status": "not_attempted", "verification_status": "not_attempted", "error": ["message": issue]]
            }
            result["items"] = rows; result["host"] = host
            let count = rows.filter { $0["status"] as? String == "verified" }.count
            let savedCount = rows.filter { $0["save_status"] as? String == "saved" }.count
            let state = !rows.isEmpty && count == rows.count ? "verified" : (savedCount > 0 ? "partial" : "not_completed")
            result["status"] = state
            jobs[i].resultData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            jobs[i].state = state
            jobs[i].message = plan.overflow ? "超过 8 项，请减少事项后重新提交；本次未创建" : "\(count)/\(plan.items.count) 项保存并验证；\(savedCount) 项事件已保存，日历字段与提醒详情见报告"
            jobs[i].prepareCompletionAnswer()
            try persist()
            // Report is durable before releasing the finite background assertion.
            finishAfterResponse(jobs[i].id, message: "本次执行结束，可查看报告")
            if jobs[i].completion_source_id != nil {
                var response = jobs[i].wire; response["completion_context"] = try jobs[i].completionContext()
                return (response, false)
            }
        default: throw error("未知计划方法")
        }
        return (jobs[i].wire, false)
    }
    private func finishAfterResponse(_ id: String, message: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if self.activeID == id { self.endWindow(message) }
        }
    }
}
