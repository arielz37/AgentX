import Foundation
@main struct V7Validation {
    static func main() throws {
        func date(_ s:String)->Date { ISO8601DateFormatter().date(from:s)! }
        func rejects(_ f:()throws->Void) { do { try f();fatalError("expected failure") } catch {} }
        func query(_ a:String,_ b:String,_ zone:String="Asia/Shanghai",_ days:Int=1)->CalendarQuery {
            .init(mode:"free_slots",start_at:a,end_at:b,time_zone:zone,duration_minutes:60,day_start_minute:0,day_end_minute:1440,assumptions:[],slot_kind:"all_day",duration_days:days)
        }
        _=try query("2027-03-01T00:00:00+08:00","2028-03-01T00:00:00+08:00").bounds()
        _=try query("2028-02-29T00:00:00+08:00","2029-02-28T00:00:00+08:00").bounds()
        rejects { _=try query("2028-02-29T00:00:00+08:00","2029-03-01T00:00:00+08:00").bounds() }
        for (a,b,hours) in [("2030-03-10T00:00:00-05:00","2030-03-11T00:00:00-04:00",23),("2030-11-03T00:00:00-04:00","2030-11-04T00:00:00-05:00",25)] {
            let q=query(a,b,"America/New_York")
            let slots=try CalendarAvailability.freeSlots(query:q,busy:[],now:date(a).addingTimeInterval(-1))
            precondition(slots.count==1 && date(slots[0].end_at).timeIntervalSince(date(slots[0].start_at))==Double(hours)*3600)
            let blocked=try CalendarAvailability.freeSlots(query:q,busy:[.init(start:date(a).addingTimeInterval(100),end:date(a).addingTimeInterval(200))],now:date(a).addingTimeInterval(-1))
            precondition(blocked.isEmpty)
        }
        let q=query("2030-10-01T12:00:00+08:00","2030-10-05T00:00:00+08:00","Asia/Shanghai",2)
        let slots=try CalendarAvailability.freeSlots(query:q,busy:[.init(start:date("2030-10-04T12:00:00+08:00"),end:date("2030-10-04T13:00:00+08:00"))],now:date("2030-09-30T00:00:00+08:00"))
        precondition(slots.count==1 && date(slots[0].start_at)==date("2030-10-02T00:00:00+08:00"))
        let zone=TimeZone(identifier:"Asia/Shanghai")!
        func rule(_ frequency:String,_ weekdays:[Int]=[],_ monthDays:[Int]=[],_ interval:Int=1,_ count:Int?=4)->RecurrenceRequest {
            .init(mode:"repeat",frequency:frequency,interval:interval,weekdays:weekdays,month_days:monthDays,months:[],end_type:count == nil ? "never" : "count",count:count,until:nil,evidence:"synthetic repeat",reason:"test")
        }
        let start=date("2030-09-30T09:00:00+08:00") // Monday
        let weekly=try CalendarOccurrences.expand(start:start,end:start.addingTimeInterval(3600),zone:zone,rule:rule("weekly",[1,3],[],2),allDay:false)
        precondition(weekly.complete && weekly.spans.count==4)
        precondition(weekly.spans[1].start==start.addingTimeInterval(2*86400) && weekly.spans[2].start==start.addingTimeInterval(14*86400))
        let monthly=try CalendarOccurrences.expand(start:date("2028-01-31T00:00:00+08:00"),end:date("2028-02-01T00:00:00+08:00"),zone:zone,rule:rule("monthly",[],[-1]),allDay:true)
        precondition(monthly.spans[1].start==date("2028-02-29T00:00:00+08:00") && monthly.complete)
        let infinite=try CalendarOccurrences.expand(start:start,end:start.addingTimeInterval(3600),zone:zone,rule:rule("daily",[],[],1,nil),allDay:false)
        precondition(!infinite.complete && infinite.spans.count==365)
        let boundaryStart=date("2030-10-06T00:00:00+08:00"), boundaryEnd=date("2030-10-07T00:00:00+08:00")
        precondition(AllDayDates.matches(start:boundaryStart,end:boundaryEnd.addingTimeInterval(-1),timeZone:nil,expectedStart:boundaryStart,expectedEnd:boundaryEnd,zone:zone))
        precondition(!AllDayDates.matches(start:boundaryStart,end:boundaryEnd.addingTimeInterval(-2),timeZone:nil,expectedStart:boundaryStart,expectedEnd:boundaryEnd,zone:zone))
        precondition(!AllDayDates.matches(start:boundaryStart,end:boundaryEnd.addingTimeInterval(86400-1),timeZone:nil,expectedStart:boundaryStart,expectedEnd:boundaryEnd,zone:zone))
        var history=PlanJob(submission_id:"history",task_id:"history",version:7,text:"整理家里",submitted_at:"2030-09-30T12:00:00Z",time_zone:"Asia/Shanghai",test_mode:true,state:"partial",message:"已保存未验证",lease_id:"lease",assistant_id:"calendar",route:.init(kind:"calendar_schedule",message:"选时",supported:["calendar"],unsupported:[]))
        history.resultData=try JSONSerialization.data(withJSONObject:["items":[["status":"saved_unverified","save_status":"saved","verification_status":"failed","readback":["title":"新整理事项","start_at":"2030-10-06T00:00:00+08:00","end_at":"2030-10-06T23:59:59+08:00"]]]])
        let evidence=history.conversationTurn.events
        precondition(evidence.count==1 && evidence[0].title=="新整理事项" && evidence[0].save_status=="saved" && evidence[0].verification_status=="failed")
        history.resultData=nil
        history.queryResult = .init(request:q,queried_at:q.start_at,event_count:1,busy_count:1,events:[.init(title:"不应冒充新建的旧事项",start_at:q.start_at,end_at:q.end_at,is_all_day:false,calendar_name:"synthetic",blocks_time:true)],events_truncated:false,free_slots:[],slots_truncated:false,calendar_count:1,scope_note:"")
        precondition(history.conversationTurn.events.isEmpty)
        print("PASS v7 pure validation: calendar-year/leap bounds, full-day scheduling/DST, contiguous days, biweekly and month-end recurrence, bounded infinite coverage.")
    }
}
