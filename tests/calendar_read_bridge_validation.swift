import Foundation
import EventKit
@main struct ReadBridgeValidation {
    @MainActor static func main() async throws {
        func date(_ s:String)->Date { ISO8601DateFormatter().date(from:s)! }
        let start=date("2030-09-28T09:00:00+08:00"), now=date("2030-09-27T00:00:00+08:00")
        let q=CalendarQuery(mode:"events",start_at:"2030-09-28T00:00:00+08:00",end_at:"2030-09-29T00:00:00+08:00",time_zone:"Asia/Shanghai",duration_minutes:60,day_start_minute:540,day_end_minute:1260,assumptions:[])
        func event(_ hour:Int,_ duration:Int=1)->EKEvent {
            let e=EKEvent(eventStore:EKEventStore());e.title="PRIVATE_EVENT";e.calendar=EKCalendar()
            e.startDate=start.addingTimeInterval(Double(hour)*3600);e.endDate=e.startDate.addingTimeInterval(Double(duration)*3600)
            e.eventIdentifier="same-series-id";return e
        }
        func rejects(_ body: () throws -> Void) { do { try body();fatalError("expected rejection") } catch {} }
        let suite="AgentX.occupancy-tests."+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let reader=CalendarReader(preferences:prefs)
        EKEventStore.reset()
        let holidays=EKCalendar();holidays.title="中国大陆节假日";holidays.isSubscribed=true;holidays.allowsContentModifications=false
        let holiday=event(-9,24);holiday.calendar=holidays;holiday.isAllDay=true;holiday.availability = .notSupported
        let meeting=event(6)
        EKEventStore.rangeEvents=[holiday,meeting];EKEventStore.calendarList=[holidays,meeting.calendar!]
        let afternoon=CalendarQuery(mode:"free_slots",start_at:"2030-09-28T14:00:00+08:00",end_at:"2030-09-28T18:00:00+08:00",time_zone:q.time_zone,duration_minutes:60,day_start_minute:840,day_end_minute:1080,assumptions:[])
        let holidayResult=try reader.query(afternoon,now:now)
        precondition(holidayResult.event_count==2 && holidayResult.busy_count==1 && holidayResult.free_slots.count==2)
        precondition(date(holidayResult.free_slots[0].start_at)==date(afternoon.start_at) && date(holidayResult.free_slots[0].end_at)==meeting.startDate)
        precondition(date(holidayResult.free_slots[1].start_at)==meeting.endDate && date(holidayResult.free_slots[1].end_at)==date(afternoon.end_at))
        precondition(holidayResult.events.contains { !$0.blocks_time && $0.occupancy_reason?.contains("节假日") == true })
        let publicText=String(data:try JSONSerialization.data(withJSONObject:holidayResult.publicSummary),encoding:.utf8)!
        precondition(!publicText.contains("PRIVATE_EVENT") && !publicText.contains("中国大陆节假日"))
        let noConflict=try reader.conflicts(start:date(afternoon.start_at),end:meeting.startDate,zone:TimeZone(identifier:q.time_zone)!,recurring:false,now:now)
        precondition(noConflict["status"] as? String=="clear")
        // Explicit inclusion overrides the heuristic and survives reader recreation.
        CalendarOccupancyPolicy.set(holidays.calendarIdentifier,included:true,preferences:prefs)
        let optedIn=try CalendarReader(preferences:prefs).query(afternoon,now:now)
        precondition(optedIn.free_slots.isEmpty && optedIn.busy_count==2)
        CalendarOccupancyPolicy.set(holidays.calendarIdentifier,included:false,preferences:prefs)
        precondition(!reader.calendarOptions().first { $0.id==holidays.calendarIdentifier }!.included)
        // A personal all-day event or work subscription must not be silently ignored.
        let personal=EKCalendar();personal.title="我的节假日"
        for source in [personal, { let c=EKCalendar();c.title="团队排班";c.isSubscribed=true;c.allowsContentModifications=false;return c }()] {
            holiday.calendar=source
            let occupied=try reader.query(afternoon,now:now)
            precondition(occupied.free_slots.isEmpty && occupied.busy_count==2)
        }
        EKEventStore.reset()
        let canceled=event(4);canceled.status = .canceled
        let free=event(6);free.availability = .free
        EKEventStore.rangeEvents=[event(0),event(2),canceled,free,event(7,0)]
        let read=try CalendarReader().query(q,now:now)
        precondition(read.event_count==4 && read.busy_count==2 && EKEventStore.saves==0)
        // Same series identifiers must not collapse distinct occurrences.
        precondition(read.events.filter{$0.blocks_time}.count==2)
        EKEventStore.rangeEvents=(0..<101).map{_ in event(0)}+[event(5)]
        let many=try CalendarReader().query(q,now:now)
        precondition(many.events.count==100 && many.event_count==102 && many.events_truncated)
        let fq=CalendarQuery(mode:"free_slots",start_at:q.start_at,end_at:q.end_at,time_zone:q.time_zone,duration_minutes:60,day_start_minute:540,day_end_minute:1260,assumptions:[])
        let available=try CalendarReader().query(fq,now:now)
        precondition(available.events.count==100 && available.events_truncated && available.busy_count==102 && available.free_slots.count==2)
        precondition(date(available.free_slots[1].start_at)==start.addingTimeInterval(6*3600))
        EKEventStore.rangeEvents=(0..<2001).map{_ in event(0)}
        rejects { _=try CalendarReader().query(fq,now:now) }
        EKEventStore.permission = .writeOnly
        rejects { _=try CalendarReader().query(q,now:now) }
        EKEventStore.permission = .fullAccess;EKEventStore.calendarList=[]
        rejects { _=try CalendarReader().query(q,now:now) }
        EKEventStore.reset()
        let invalid=event(0);invalid.endDate=nil;EKEventStore.rangeEvents=[invalid]
        rejects { _=try CalendarReader().query(q,now:now) }

        EKEventStore.reset();EKEventStore.rangeEvents=[event(0)]
        let check=try CalendarReader().conflicts(start:start,end:start.addingTimeInterval(3600),zone:TimeZone(identifier:"Asia/Shanghai")!,recurring:true,now:now)
        precondition(check["status"] as? String=="conflict" && check["coverage"] as? String=="first_occurrence_only")
        let checkText=String(data:try JSONSerialization.data(withJSONObject:check),encoding:.utf8)!
        precondition(!checkText.contains("PRIVATE_EVENT"))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let bridge=CalendarBridge(executionLocation:"iphone_native_app",ledgerURL:folder.appendingPathComponent("ledger.json"))
        bridge.mayWrite={true};bridge.checkConflicts=true
        _=try await bridge.handle("calendar_lock",[:])
        let status=try await bridge.handle("calendar_status",[:])
        func execute(_ id:String,_ hour:Int) async throws -> [String:Any] {
            let a=start.addingTimeInterval(Double(hour)*3600)
            let item:[String:Any]=["item_id":id,"title":"AgentX Test read-check","start_at":AlertPolicy.format(a),"end_at":AlertPolicy.format(a.addingTimeInterval(3600)),"time_zone":"Africa/Abidjan"]
            let result=try await bridge.handle("calendar_execute",["session_id":status["session_id"]!,"task_id":"read-task","test_mode":true,"items":[item]])
            return (result["items"] as! [[String:Any]])[0]
        }
        let blocked=try await execute("busy",0)
        precondition(blocked["status"] as? String=="not_created_conflict" && blocked["save_status"] as? String=="not_attempted" && EKEventStore.saves==0)
        let queries=EKEventStore.rangeQueries
        let replay=try await execute("busy",0)
        precondition(replay["deduplicated"] as? Bool==true && EKEventStore.rangeQueries==queries)
        // A fresh query must see items saved earlier, including within a batch.
        EKEventStore.rangeEvents=nil
        let saved=try await execute("clear",1)
        precondition(saved["status"] as? String=="verified" && EKEventStore.saves==1)
        let next=try await execute("second",1)
        precondition(next["status"] as? String=="not_created_conflict" && EKEventStore.saves==1)
        let adjacent=try await execute("adjacent",2)
        precondition(adjacent["status"] as? String=="verified" && EKEventStore.saves==2)
        print("PASS EventKit READ TEST DOUBLE: occurrences retained, free/canceled filtering, full busy set before truncation, invalid/oversized/unauthorized fail closed, conflict blocks save, replay dedup, adjacent succeeds. No real calendar accessed.")
    }
}
