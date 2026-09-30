import EventKit
import Foundation

// EventKit runs inside the iPhone process (runner or native host), never on the Mac.
// MainActor serializes synchronous writes; preparation is the only permission prompt.
@MainActor final class CalendarBridge {
    private let executionLocation: String
    private let ledgerURL: URL?
    private var storageError: String?
    var comprehensiveConflicts = false
    var checkConflicts = false // New v4 submissions only; immutable legacy tasks keep their behavior.
    var mayWrite: (() -> Bool)?
    init(executionLocation: String = "iphone_xctest_runner", ledgerURL: URL? = nil, stores: CalendarEventStores? = nil) {
        self.executionLocation = executionLocation; self.ledgerURL = ledgerURL; self.stores = stores ?? .shared
        if let ledgerURL, FileManager.default.fileExists(atPath: ledgerURL.path) {
            do {
                let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL))
                guard let rows = raw as? [String: [String: Any]] else { throw NSError(domain: "ledger", code: 1) }
                for (key, row) in rows {
                    guard let encoded = row["payload"] as? String, let payload = Data(base64Encoded: encoded),
                          var result = row["result"] as? [String: Any] else { throw NSError(domain: "ledger", code: 2) }
                    if result["save_status"] as? String == "attempted" {
                        result["save_status"] = "unknown"; result["status"] = "unknown"
                        result["error"] = ["message": "Process ended during save; inspect calendar. Never recreate automatically."]
                    }
                    ledger[key] = (payload, result)
                }
            } catch { storageError = "ledger_unreadable: no writes allowed" }
        }
    }
    private func persistLedger() throws {
        guard storageError == nil else { throw failure(storageError!) }
        guard let ledgerURL else { return }
        let rows = ledger.mapValues { ["payload": $0.payload.base64EncodedString(), "result": $0.result] as [String: Any] }
        do {
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]).write(to: ledgerURL, options: .atomic)
        } catch { storageError = "ledger_write_failed: stopped further writes"; throw error }
    }
    private var scope: String { ledgerURL == nil ? "this_runner_session_only" : "persistent_reservations_not_exactly_once" }
    private let sessionID = UUID().uuidString
    private let stores: CalendarEventStores
    private var store: EKEventStore { stores.writer }
    private var preparing = false
    private(set) var isLocked = false
    private var ledger: [String: (payload: Data, result: [String: Any])] = [:]

    private func now() -> String { Self.format(Date()) }
    private static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    private func status() -> [String: Any] {
        let auth = EKEventStore.authorizationStatus(for: .event)
        let label: String
        switch auth {
        case .notDetermined: label = "not_determined"
        case .restricted: label = "restricted"
        case .denied: label = "denied"
        case .fullAccess: label = "full_access"
        case .writeOnly: label = "write_only"
        @unknown default: label = "unknown"
        }
        return ["session_id": sessionID, "authorization": label, "calendar_only": isLocked,
                "preparing": preparing, "device_time": now(), "execution_location": executionLocation,
                "deduplication_scope": scope, "ledger_items": ledger.count,
                "runner_usage_description_present": Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil]
    }

    @MainActor
    func handle(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "calendar_status": return status()
        case "calendar_prepare":
            guard !isLocked, !preparing else { throw failure("Preparation unavailable after lock or during another preparation") }
            guard params["allow_permission_prompt"] as? Bool == true else {
                throw failure("Preparation requires allow_permission_prompt=true; run before gaming")
            }
            preparing = true
            defer { preparing = false }
            if !authorized { _ = try await store.requestFullAccessToEvents() }
            preparing = false
            return status()
        case "calendar_lock":
            guard !preparing, authorized else { throw failure("Full calendar access is required before locking") }
            isLocked = true // Irreversible for this runner session.
            return status()
        case "calendar_execute":
            guard !preparing, isLocked else { throw failure("Prepare and lock the calendar-only session first") }
            guard params["session_id"] as? String == sessionID else {
                throw failure("session_mismatch: runner restarted or wrong session; do not automatically resend old tasks")
            }
            let taskID = try identifier(params["task_id"], name: "task_id")
            guard let items = params["items"] as? [[String: Any]], (1...(executionLocation == "iphone_native_app" ? 8 : 3)).contains(items.count),
                  Set(params.keys).isSubset(of: ["session_id", "task_id", "items", "test_mode"]) else {
                throw failure("Expected session_id, task_id and 1...3 items only")
            }
            let received = now()
            let results = items.map { executeItem(taskID: taskID, item: $0, testMode: params["test_mode"] as? Bool ?? true) }
            let verified = results.filter { $0["status"] as? String == "verified" }.count
            return ["session_id": sessionID, "task_id": taskID, "received_at": received,
                    "completed_at": now(), "execution_location": executionLocation,
                    "status": verified == items.count ? "verified" : (results.contains { $0["save_status"] as? String == "saved" } ? "partial" : "failed"),
                    "items": results, "deduplication_scope": scope]
        default: throw failure("Unknown calendar RPC")
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "AgentX.Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func identifier(_ value: Any?, name: String) throws -> String {
        guard let s = value as? String, s.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil else {
            throw failure("\(name) must contain 1...80 ASCII letters, digits, underscores or hyphens")
        }
        return s
    }

    @MainActor private func executeItem(taskID: String, item: [String: Any], testMode: Bool) -> [String: Any] {
        let received = now()
        var result: [String: Any] = ["task_id": taskID, "item_id": item["item_id"] ?? NSNull(),
            "request": item, "received_at": received, "saved_at": NSNull(), "verified_at": NSNull(),
            "event_id": NSNull(), "readback": NSNull(), "error": NSNull(), "status": "failed",
            "save_status": "not_attempted", "verification_status": "not_attempted", "deduplicated": false]
        var key: String?
        var payload: Data?
        do {
            let itemID = try identifier(item["item_id"], name: "item_id")
            key = taskID + "/" + itemID
            payload = try AlertPolicy.canonicalPayload(item)
            if let prior = ledger[key!] {
                guard try AlertPolicy.canonicalPayload(AlertPolicy.object(prior.payload)) == payload else { throw failure("id_conflict: same task_id/item_id has different content") }
                var replay = prior.result
                replay["deduplicated"] = true
                replay["retry_received_at"] = received
                // A replay reports the original observation; it does not claim a new readback.
                return replay
            }
            guard storageError == nil else { throw failure(storageError!) }
            guard mayWrite?() ?? true else {
                result["status"] = "not_executed_window_expired"
                throw failure("background_budget_insufficient: no save attempted")
            }
            let request = try CalendarEventInput(item, productMode: executionLocation == "iphone_native_app", testMode: testMode)
            guard authorized else { throw failure("permission_missing: full access required; no prompt during execution") }
            _ = stores.freshWriter()
            guard let calendar = store.defaultCalendarForNewEvents, calendar.allowsContentModifications else {
                throw failure("No writable default calendar; configure Calendar manually before another session")
            }
            if checkConflicts {
                let check = try comprehensiveConflicts ? CalendarReader(stores: stores).comprehensiveConflicts(request) : CalendarReader(stores: stores).conflicts(start: request.start, end: request.end, zone: request.zone,
                    recurring: request.features?.recurrence.mode == "repeat")
                result["conflict_check"] = check
                if check["status"] as? String == "conflict" {
                    result["status"] = "not_created_conflict"
                    throw failure("目标时段与已有日程冲突，本项未创建；可查看建议时段，没有自动改期。")
                }
                guard mayWrite?() ?? true else { throw failure("查询后执行窗口不足，本项未保存。") }
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = request.title
            event.location = request.location
            event.startDate = request.start
            event.endDate = request.end
            event.timeZone = request.zone
            event.isAllDay = request.features?.is_all_day ?? false
            event.url = request.features?.url.flatMap(URL.init(string:))
            let recurring = request.features?.recurrence.mode == "repeat"
            let alertEvaluation = AlertPolicy.evaluate(request.alerts, start: request.start, zone: request.zone, now: Date(), recurring: recurring)
            if request.alerts != nil {
                result["alerts"] = alertEvaluation.wire
                result["event_verification_status"] = "not_attempted"
            }
            event.alarms = alertEvaluation.configured.map { alarm in
                alarm.type == "relative" ? EKAlarm(relativeOffset: Double(alarm.offset!)) : EKAlarm(absoluteDate: alarm.fire)
            }
            event.recurrenceRules = request.features?.recurrence.eventKitRule(zone: request.zone).map { [$0] }
            let marker = "AgentX task_id=\(taskID) item_id=\(itemID)"
            let expectedNotes = request.features?.notes.map { $0 + "\n\n" + marker } ?? marker
            event.notes = expectedNotes
            // Record reservation before the side effect; a save error is conservatively not retried.
            result["save_status"] = "attempted"
            ledger[key!] = (payload!, result)
            try persistLedger() // durable reservation MUST precede EventKit
            try store.save(event, span: recurring ? .futureEvents : .thisEvent, commit: true)
            result["saved_at"] = now()
            result["save_status"] = "saved"
            result["status"] = "saved_unverified"
            let eventID = event.eventIdentifier
            result["event_id"] = eventID ?? NSNull() as Any
            ledger[key!] = (payload!, result)
            try persistLedger()

            // Independent, long-lived read connection with its cached objects
            // invalidated. Query the saved ID, never return the write-side event.
            let reader = stores.freshReader()
            let readableCount = reader.calendars(for: .event).count
            result["readback_observation"] = ["checked_at": now(), "calendar_count": readableCount,
                "full_access": authorized, "cache_reset": true, "connection": "independent_reused_reader"]
            guard readableCount > 0 else { throw failure("calendar_read_unavailable: 保存成功后日历接口未返回可读日历，结果未验证，不会重复创建") }
            guard let eventID, let read = reader.event(withIdentifier: eventID) else {
                throw failure("readback_missing: saved event could not be queried")
            }
            let readback: [String: Any] = ["title": read.title ?? "", "start_at": Self.format(read.startDate),
                "end_at": Self.format(read.endDate), "time_zone": read.timeZone?.identifier ?? "",
                "location": read.location ?? NSNull() as Any, "is_all_day": read.isAllDay, "alarm_count": read.alarms?.count ?? 0,
                "attendee_count": read.attendees?.count ?? 0, "recurrence_count": read.recurrenceRules?.count ?? 0]
            var fullReadback = readback
            let alarms = read.alarms ?? []
            let rawAlarms: [[String: Any]] = alarms.map { alarm in
                let fire = alarm.absoluteDate ?? read.startDate.addingTimeInterval(alarm.relativeOffset)
                return ["trigger_type": alarm.absoluteDate == nil ? "relative" : "absolute",
                        "offset_seconds": alarm.relativeOffset,
                        "absolute_at": alarm.absoluteDate.map(Self.format) as Any? ?? NSNull(),
                        "trigger_at": Self.format(fire), "has_location": alarm.structuredLocation != nil,
                        "proximity": alarm.proximity.rawValue]
            }
            fullReadback["alarms"] = rawAlarms
            if request.features != nil {
                fullReadback["notes"] = read.notes ?? NSNull() as Any
                fullReadback["url"] = read.url?.absoluteString ?? NSNull() as Any
                fullReadback["recurrence_rules"] = RecurrenceRequest.snapshot(read.recurrenceRules)
                result["calendar_features_verification_status"] = "not_attempted"
            }
            result["readback"] = fullReadback
            let alertsMatch = AlertPolicy.matches(alertEvaluation.configured.map(\.fire),
                alarms.map { $0.absoluteDate ?? read.startDate.addingTimeInterval($0.relativeOffset) },
                unsupported: alarms.contains { $0.structuredLocation != nil || $0.proximity != .none || (recurring && $0.absoluteDate != nil) })
            if request.alerts != nil {
                var alertResult = alertEvaluation.wire
                alertResult["readback"] = rawAlarms
                alertResult["verified_at"] = now()
                alertResult["verification_status"] = alertsMatch ? "verified" : "failed"
                if request.alerts?.mode != "suggested" {
                    alertResult["user_requirement_status"] = alertsMatch && alertEvaluation.complete ? "met" : "unmet"
                }
                result["alerts"] = alertResult
            }
            let datesMatch: Bool
            if request.features?.is_all_day == true && read.isAllDay {
                datesMatch = AllDayDates.matches(start: read.startDate, end: read.endDate, timeZone: read.timeZone, expectedStart: request.start, expectedEnd: request.end, zone: request.zone)
                result["date_verification_basis"] = "same_local_all_day_dates; raw readback retained"
            } else {
                datesMatch = abs(read.startDate.timeIntervalSince(request.start)) < 1 && abs(read.endDate.timeIntervalSince(request.end)) < 1 && read.timeZone?.identifier == request.zone.identifier
            }
            guard read.title == request.title, datesMatch,
                  (read.location ?? "") == (request.location ?? ""), read.isAllDay == (request.features?.is_all_day ?? false),
                  (read.attendees ?? []).isEmpty,
                  request.features?.recurrence.matches(read.recurrenceRules, zone: request.zone) ?? (read.recurrenceRules ?? []).isEmpty,
                  request.features == nil || (read.notes == expectedNotes && read.url == request.features?.url.flatMap(URL.init(string:))) else {
                throw failure("readback_mismatch: saved fields differ; inspect this event manually")
            }
            if request.features != nil { result["calendar_features_verification_status"] = "verified" }
            if request.alerts != nil { result["event_verification_status"] = "verified" }
            guard alertsMatch else { throw failure("alarm_readback_mismatch: inspect saved event; never recreate automatically") }
            result["verified_at"] = now()
            result["verification_status"] = "verified"
            result["status"] = alertEvaluation.complete ? "verified" : "partial"
        } catch {
            let e = error as NSError
            result["error"] = ["message": e.localizedDescription, "domain": e.domain, "code": e.code]
            if result["save_status"] as? String == "saved" {
                result["verification_status"] = "failed"
                if item["calendar"] != nil && result["calendar_features_verification_status"] as? String != "verified" { result["calendar_features_verification_status"] = "failed" }
                if item["alerts"] != nil {
                    if result["event_verification_status"] as? String != "verified" {
                        result["event_verification_status"] = "failed"
                        if var a = result["alerts"] as? [String: Any], a["user_requirement_status"] as? String == "met" {
                            a["user_requirement_status"] = "unmet"; result["alerts"] = a
                        }
                    }
                    if var a = result["alerts"] as? [String: Any], a["verification_status"] as? String == "not_attempted" {
                        a["verification_status"] = "failed"
                        if a["user_requirement_status"] as? String == "pending_verification" { a["user_requirement_status"] = "unknown" }
                        result["alerts"] = a
                    }
                }
            } else if result["save_status"] as? String == "attempted" {
                result["status"] = "unknown"
                result["save_status"] = "unknown" // Do not assume a thrown save is safe to repeat.
            }
        }
        // Never replace the ledger for a conflicting payload.
        if let key, let payload, ledger[key] == nil || ledger[key]?.payload == payload {
            ledger[key] = (payload, result)
            do { try persistLedger() }
            catch { result["persistence_error"] = "Durable ledger unavailable; do not resubmit with new IDs" }
        }
        return result
    }
}
