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
    private let storage: PlanStore
    private let calendar: CalendarBridge
    private var server: SimulatorRPCServer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var deadline: Date?
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
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AgentX pending plan") { [weak self] in
            Task { @MainActor in self?.endWindow("系统后台窗口已结束，未执行项没有自动重试") }
        }
        guard backgroundTask != .invalid else { throw error("系统拒绝后台窗口") }
        activeID = id; deadline = Date().addingTimeInterval(45)
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endWindow("45 秒窗口已结束") }
        }
    }
    @discardableResult func submit(_ text: String, assistant: String) -> Bool {
        guard canSubmit(text), ["auto", "calendar"].contains(assistant) else { message = "请检查连接；输入上限 4000 字"; return false }
        do {
            let id = "ax-" + UUID().uuidString
            try openWindow(id: id)
            jobs.insert(PlanJob(submission_id: id, task_id: id, version: 3, text: text,
                submitted_at: ISO8601DateFormatter().string(from: Date()), time_zone: TimeZone.current.identifier,
                test_mode: testMode, state: "queued", message: "已保存在手机，等待 Mac 接收", lease_id: lease,
                assistant_id: assistant), at: 0)
            try persist(); message = "已提交，可以留在这里或切回其他 App。"
            return true
        } catch { message = error.localizedDescription; endWindow(message); return false }
    }
    func continueJob(_ id: String) {
        guard ready, authorized, modelReady, Date().timeIntervalSince(heartbeat) < 5, !storageFailed,
              let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == "window_expired", jobs[i].plan != nil else { return }
        do {
            try openWindow(id: id)
            jobs[i].lease_id = lease; jobs[i].state = "planned"; jobs[i].message = "用户主动继续同一计划；可留在此页或切回游戏"
            try persist(); message = jobs[i].message
        } catch { endWindow(error.localizedDescription) }
    }
    func sceneChanged(_ phase: ScenePhase) {
        // Keep the same task and lease across foreground/background transitions.
        // An expired lease remains expired; returning here never rearms old tasks.
        if !preview && phase == .active { start(); Task { await refreshAuthorization() } }
    }
    private func endWindow(_ text: String) {
        if let id = activeID, let i = jobs.firstIndex(where: { $0.id == id }), ["queued", "parsing", "planned"].contains(jobs[i].state) {
            jobs[i].state = "window_expired"; jobs[i].message = "日历未执行：\(text)"; try? persist()
        }
        activeID = nil; deadline = nil; timer?.invalidate(); timer = nil
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
    private func decodeRoute(_ params: [String: Any], job: PlanJob, hasPlan: Bool) throws -> ModuleRoute {
        guard let raw = params["route"] as? [String: Any], let review = params["review_status"] as? String else { throw error("缺少能力路由或复核结果") }
        let data = try JSONSerialization.data(withJSONObject: raw)
        let route = try JSONDecoder().decode(ModuleRoute.self, from: data)
        try AgentXRouting.validate(route, hasPlan: hasPlan, review: review, scope: job.scope)
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
        guard method.hasPrefix("plan_") else { throw error("本宿主只允许计划处理，不提供 UI 自动化或远程授权") }
        let i = try index(p)
        switch method {
        case "plan_claim":
            if jobs[i].state == "queued" { jobs[i].state = "parsing"; jobs[i].message = "Mac 已接收，正在理解；可以切回游戏"; try persist(); message = jobs[i].message }
        case "plan_fail":
            guard jobs[i].plan == nil, jobs[i].resultData == nil else { throw error("不能覆盖已有计划或结果") }
            jobs[i].state = "failed"; jobs[i].message = p["message"] as? String ?? "模型失败"; try persist()
            if activeID == jobs[i].id { endWindow(jobs[i].message) }
        case "plan_route":
            guard jobs[i].plan == nil, jobs[i].resultData == nil, ["queued", "parsing", "window_expired"].contains(jobs[i].state) else { throw error("任务已结束") }
            let route = try decodeRoute(p, job: jobs[i], hasPlan: false)
            jobs[i].route = route; jobs[i].review_status = p["review_status"] as? String
            jobs[i].state = AgentXRouting.terminalState(route.kind, scope: jobs[i].scope)
            jobs[i].message = route.message; try persist()
            if activeID == jobs[i].id { endWindow(route.message) }
        case "plan_store":
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
            if jobs[i].resultData != nil { return (jobs[i].wire, false) }
            guard jobs[i].state == "planned", jobs[i].id == activeID, p["lease_id"] as? String == lease,
                  let plan = jobs[i].plan else { throw error("未执行：计划状态或窗口不匹配；没有自动重放") }
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
            try AgentXRouting.validate(route, hasPlan: true, review: review, scope: jobs[i].scope)
            guard canWrite else { throw error("未执行：执行窗口或后台预算不足；没有自动重放") }
            jobs[i].state = "executing"; jobs[i].message = "正在手机保存和读回"; try persist()
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
            try persist()
            // Report is durable before releasing the finite background assertion.
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); self.endWindow("本次执行结束，可查看报告") }
        default: throw error("未知计划方法")
        }
        return (jobs[i].wire, false)
    }
}
