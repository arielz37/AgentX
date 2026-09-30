import Foundation
import EventKit

@main struct BridgeValidation {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func spec(_ id: String, _ offset: Int) -> AlertSpec { AlertSpec(alert_id: id, trigger_type: "relative", offset_seconds: offset, at: nil, source: "explicit", evidence: "要求", reason: "测试") }
        let two = AlertRequest(mode: "explicit", evidence: "要求", reason: "测试", count_limit: nil, no_extra: true, overflow: false, items: [spec("a1", -86400), spec("a2", -7200)])
        let start = Date().addingTimeInterval(172800)
        func item(_ alerts: AlertRequest? = two) -> [String: Any] {
            var i: [String: Any] = ["item_id":"i1", "title":"AgentX Test mock", "start_at":AlertPolicy.format(start), "end_at":AlertPolicy.format(start.addingTimeInterval(3600)), "time_zone":"Africa/Abidjan"]
            if let alerts { i["alerts"] = alerts.wire }; return i
        }
        func setup(_ name: String) async throws -> (CalendarBridge, String, URL) {
            EKEventStore.reset()
            let url=folder.appendingPathComponent(name+".json")
            let bridge=CalendarBridge(executionLocation: "iphone_native_app", ledgerURL: url, stores: CalendarEventStores())
            bridge.mayWrite = { true }
            _ = try await bridge.handle("calendar_lock", [:])
            let status=try await bridge.handle("calendar_status", [:])
            return (bridge,status["session_id"] as! String,url)
        }
        func execute(_ bridge: CalendarBridge, _ session: String, _ i: [String: Any]) async throws -> [String: Any] {
            let response=try await bridge.handle("calendar_execute", ["session_id":session,"task_id":"mock-task","test_mode":true,"items":[i]])
            return (response["items"] as! [[String: Any]])[0]
        }
        let (b,s,url)=try await setup("successful")
        EKEventStore.beforeSave = {
            let raw=try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: [String: Any]]
            let reservation=raw["mock-task/i1"]!["result"] as! [String: Any]
            precondition(reservation["save_status"] as? String == "attempted")
        }
        let success=try await execute(b,s,item())
        precondition(success["status"] as? String == "verified" && EKEventStore.saves == 1 && EKEventStore.queries == 1 && EKEventStore.instances == 2)
        var reorder=item(); var a=two.wire;a["items"]=Array((a["items"] as! [[String:Any]]).reversed());reorder["alerts"]=a
        let replay=try await execute(b,s,reorder)
        precondition(replay["deduplicated"] as? Bool == true && EKEventStore.saves == 1)
        precondition(replay["saved_at"] as? String == success["saved_at"] as? String)
        let conflict=try await execute(b,s,item(nil))
        precondition(conflict["status"] as? String == "failed" && EKEventStore.saves == 1)
        let restarted=CalendarBridge(executionLocation: "iphone_native_app",ledgerURL:url);restarted.mayWrite={true}
        _ = try await restarted.handle("calendar_lock", [:]);let rs=try await restarted.handle("calendar_status", [:])
        let restartedReplay=try await execute(restarted,rs["session_id"] as! String,item())
        precondition(restartedReplay["deduplicated"] as? Bool == true && EKEventStore.saves == 1)

        let (p,ps,_)=try await setup("partial")
        let partialRequest=AlertRequest(mode:"explicit",evidence:"要求",reason:"测试",count_limit:nil,no_extra:true,overflow:false,items:[spec("a1",-259200),spec("a2",-7200)])
        let partial=try await execute(p,ps,item(partialRequest));let pa=partial["alerts"] as! [String:Any]
        precondition(partial["status"] as? String == "partial" && pa["verification_status"] as? String == "verified" && pa["user_requirement_status"] as? String == "unmet")
        precondition(partial["event_verification_status"] as? String == "verified")

        for mode in ["drop", "extra", "shift", "reorder", "absolute", "missing"] {
            let (b,s,_)=try await setup(mode)
            EKEventStore.readTransform = { e in
                if mode == "drop" { e.alarms = [] }
                if mode == "extra" { e.alarms?.append(EKAlarm(relativeOffset:-60)) }
                if mode == "shift" { e.alarms?[0].relativeOffset += 120 }
                if mode == "reorder" { e.alarms = e.alarms?.reversed() }
                if mode == "absolute" { e.alarms = e.alarms?.map { EKAlarm(absoluteDate:e.startDate.addingTimeInterval($0.relativeOffset)) } }
                return mode == "missing" ? nil : e
            }
            let result=try await execute(b,s,item())
            precondition(result["status"] as? String == (["reorder","absolute"].contains(mode) ? "verified" : "saved_unverified"))
            _=try await execute(b,s,item());precondition(EKEventStore.saves == 1)
        }
        let (f,fs,_)=try await setup("save-unknown");EKEventStore.failAfterSave=true
        let unknown=try await execute(f,fs,item());precondition(unknown["status"] as? String == "unknown")
        _=try await execute(f,fs,item());precondition(EKEventStore.saves == 1)
        let (old,os,_)=try await setup("legacy")
        let oldResult=try await execute(old,os,item(nil))
        precondition(oldResult["status"] as? String == "verified" && oldResult["alerts"] == nil)
        _=try await execute(old,os,item());precondition(EKEventStore.saves == 1)
        var civil = Calendar(identifier:.gregorian);civil.timeZone=TimeZone(identifier:"Africa/Abidjan")!
        let weekday=(civil.component(.weekday,from:start)+5)%7+1
        func capabilities(_ count: Int = 4) -> CalendarFeatures {
            let rule=RecurrenceRequest(mode:"repeat",frequency:"weekly",interval:2,weekdays:[weekday,weekday % 7 + 1],month_days:[],months:[],end_type:"count",count:count,until:nil,evidence:"重复",reason:"测试")
            return CalendarFeatures(is_all_day:false,notes:"带泳镜",url:"https://example.com/swim",recurrence:rule,reason:"明确要求",unsupported:[])
        }
        func recurringItem(_ count: Int = 4) -> [String:Any] { var value=item();value["calendar"]=capabilities(count).wire;return value }
        let (series,ss,surl)=try await setup("series")
        let seriesResult=try await execute(series,ss,recurringItem())
        precondition(seriesResult["status"] as? String == "verified" && EKEventStore.saves == 1)
        precondition(seriesResult["calendar_features_verification_status"] as? String == "verified")
        let read=seriesResult["readback"] as! [String:Any]
        precondition(read["recurrence_count"] as? Int == 1 && read["url"] as? String == "https://example.com/swim")
        precondition((read["notes"] as! String).hasPrefix("带泳镜"))
        let different=try await execute(series,ss,recurringItem(5))
        precondition(different["status"] as? String == "failed" && EKEventStore.saves == 1)
        let restartedSeries=CalendarBridge(executionLocation:"iphone_native_app",ledgerURL:surl);restartedSeries.mayWrite={true}
        _=try await restartedSeries.handle("calendar_lock",[:]);let sstatus=try await restartedSeries.handle("calendar_status",[:])
        var reordered=recurringItem();var featureWire=capabilities().wire;var r=featureWire["recurrence"] as! [String:Any];r["weekdays"]=[weekday % 7 + 1,weekday];featureWire["recurrence"]=r;reordered["calendar"]=featureWire
        let repeated=try await execute(restartedSeries,sstatus["session_id"] as! String,reordered)
        precondition(repeated["deduplicated"] as? Bool == true && EKEventStore.saves == 1)
        for mutation in ["drop_rule","interval","count","notes","url","all_day","absolute_alarm"] {
            let (b,s,_)=try await setup("series-"+mutation)
            EKEventStore.readTransform = { e in
                switch mutation {
                case "drop_rule": e.recurrenceRules=[]
                case "interval": e.recurrenceRules?[0].interval=1
                case "count": e.recurrenceRules?[0].recurrenceEnd?.occurrenceCount=99
                case "notes": e.notes="lost notes"
                case "url": e.url=nil
                case "all_day": e.isAllDay=true
                default: e.alarms=e.alarms?.map { EKAlarm(absoluteDate:e.startDate.addingTimeInterval($0.relativeOffset)) }
                }
                return e
            }
            let mismatch=try await execute(b,s,recurringItem())
            precondition(mismatch["save_status"] as? String == "saved" && mismatch["verification_status"] as? String == "failed")
            _=try await execute(b,s,recurringItem());precondition(EKEventStore.saves == 1)
        }
        let (allDay,ads,_)=try await setup("all-day")
        let noRule=RecurrenceRequest(mode:"none",frequency:nil,interval:1,weekdays:[],month_days:[],months:[],end_type:"never",count:nil,until:nil,evidence:nil,reason:"无重复")
        var entire=item(nil)
        let dayStart=civil.startOfDay(for:start)
        entire["start_at"]=AlertPolicy.format(dayStart);entire["end_at"]=AlertPolicy.format(civil.date(byAdding:.day,value:3,to:dayStart)!)
        entire["calendar"]=CalendarFeatures(is_all_day:true,notes:"多日活动",url:nil,recurrence:noRule,reason:"三天全天",unsupported:[]).wire
        let allDayResult=try await execute(allDay,ads,entire)
        precondition(allDayResult["status"] as? String == "verified" && (allDayResult["readback"] as! [String:Any])["is_all_day"] as? Bool == true)
        for (label,offset,passes) in [("native-floating-end", -1.0, true),("wrong-extra-day",86399.0,false),("invalid-end-time",-60.0,false)] {
            let (bridge,session,_)=try await setup(label)
            EKEventStore.readTransform={ e in e.timeZone=nil;e.endDate=e.endDate.addingTimeInterval(offset);return e }
            let result=try await execute(bridge,session,entire)
            precondition((result["status"] as? String == "verified")==passes)
        }
        print("PASS calendar capabilities TEST DOUBLE: single series save, all-day span, persisted dedup/conflict, altered recurrence/notes/url/all-day/alarms never falsely verified.")
        print("PASS EventKit TEST DOUBLE: reservation-before-save, fresh readback, partial fulfillment, durable retry/conflict, failures and legacy. No real calendar writes.")
    }
}
