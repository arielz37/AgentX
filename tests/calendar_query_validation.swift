import Foundation
@main struct QueryValidation {
    static func main() throws {
        func date(_ s: String) -> Date { ISO8601DateFormatter().date(from:s)! }
        func rejects(_ body: () throws -> Void) { do { try body();fatalError("expected rejection") } catch {} }
        let q=CalendarQuery(mode:"free_slots",start_at:"2030-09-28T00:00:00+08:00",end_at:"2030-09-29T00:00:00+08:00",time_zone:"Asia/Shanghai",duration_minutes:60,day_start_minute:540,day_end_minute:1260,assumptions:[])
        let start=date("2030-09-28T09:00:00+08:00")
        func span(_ a: Int,_ b: Int) -> CalendarAvailability.Span { .init(start:start.addingTimeInterval(Double(a)*3600),end:start.addingTimeInterval(Double(b)*3600)) }
        let slots=try CalendarAvailability.freeSlots(query:q,busy:[span(1,3),span(2,4),span(4,5),span(8,10)],now:start)
        precondition(slots.count==3)
        precondition(date(slots[0].end_at)==start.addingTimeInterval(3600))
        precondition(date(slots[1].start_at)==start.addingTimeInterval(5*3600))
        precondition(!CalendarAvailability.overlaps(span(0,1),span(1,2)))
        // Reported real-world case: only 15–16 occupied in a 14–18 query.
        let afternoon=CalendarQuery(mode:"free_slots",start_at:"2026-10-02T14:00:00+08:00",end_at:"2026-10-02T18:00:00+08:00",time_zone:"Asia/Shanghai",duration_minutes:60,day_start_minute:840,day_end_minute:1080,assumptions:[])
        let meeting=CalendarAvailability.Span(start:date("2026-10-02T15:00:00+08:00"),end:date("2026-10-02T16:00:00+08:00"))
        let before=date("2026-09-30T00:00:00+08:00")
        let afternoonSlots=try CalendarAvailability.freeSlots(query:afternoon,busy:[meeting],now:before)
        precondition(afternoonSlots.count==2)
        precondition(date(afternoonSlots[0].start_at)==date(afternoon.start_at) && date(afternoonSlots[0].end_at)==meeting.start)
        precondition(date(afternoonSlots[1].start_at)==meeting.end && date(afternoonSlots[1].end_at)==date(afternoon.end_at))
        let allDay=CalendarAvailability.Span(start:date("2026-10-02T00:00:00+08:00"),end:date("2026-10-03T00:00:00+08:00"))
        let dayBlocked=try CalendarAvailability.freeSlots(query:afternoon,busy:[meeting,allDay],now:before)
        precondition(dayBlocked.isEmpty)
        let occupied=try CalendarAvailability.freeSlots(query:q,busy:[span(-20,30)],now:start)
        let past=try CalendarAvailability.freeSlots(query:q,busy:[],now:start.addingTimeInterval(13*3600))
        precondition(occupied.isEmpty && past.isEmpty)
        for (a,b,hours) in [("2030-03-10T00:00:00-05:00","2030-03-11T00:00:00-04:00",23),("2030-11-03T00:00:00-04:00","2030-11-04T00:00:00-05:00",25)] {
            let dst=CalendarQuery(mode:"free_slots",start_at:a,end_at:b,time_zone:"America/New_York",duration_minutes:60,day_start_minute:0,day_end_minute:1440,assumptions:[])
            let slots=try CalendarAvailability.freeSlots(query:dst,busy:[],now:date(a))
            precondition(slots.count==1 && date(slots[0].end_at).timeIntervalSince(date(slots[0].start_at))==Double(hours)*3600)
        }
        let route=ModuleRoute(kind:"calendar_query",message:"查询",supported:["calendar"],unsupported:[])
        try AgentXRouting.validate(route,hasPlan:false,hasQuery:true,review:"passed",scope:"auto")
        rejects { try AgentXRouting.validate(route,hasPlan:true,hasQuery:true,review:"passed",scope:"auto") }
        rejects { try AgentXRouting.validate(route,hasPlan:false,hasQuery:true,review:"failed",scope:"auto") }
        let result=CalendarQueryResult(request:q,queried_at:q.start_at,event_count:1,busy_count:1,events:[.init(title:"PRIVATE_SENTINEL",start_at:q.start_at,end_at:q.end_at,is_all_day:true,calendar_name:"PRIVATE_CALENDAR",blocks_time:true)],events_truncated:false,free_slots:[],slots_truncated:false,calendar_count:1,scope_note:"snapshot")
        var job=PlanJob(submission_id:"read-test",task_id:"read-test",version:4,text:"查询明天",submitted_at:q.start_at,time_zone:q.time_zone,test_mode:true,state:"query_complete",message:"查询完成",lease_id:"lease",assistant_id:"calendar",route:route,review_status:"passed",query:q,queryResult:result)
        job.resultData=try JSONSerialization.data(withJSONObject:result.publicSummary)
        let wire=String(data:try JSONSerialization.data(withJSONObject:job.wire),encoding:.utf8)!
        precondition(!wire.contains("PRIVATE_SENTINEL") && !wire.contains("PRIVATE_CALENDAR") && !wire.contains("queryResult"))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=PlanStore(directory:folder);try store.save([job])
        let restored=try store.load();precondition(restored[0].queryResult?.events[0].title=="PRIVATE_SENTINEL")
        rejects { _=try job.answerContext() } // v4 history never uploads by upgrading the app.
        var newJob=PlanJob(submission_id:"v5",task_id:"v5",version:5,text:"明天有空吗",submitted_at:q.start_at,time_zone:q.time_zone,test_mode:true,state:"answer_pending",message:"读取成功",lease_id:"lease",assistant_id:"calendar",query:q,queryResult:result,query_result_id:"snapshot-new")
        let context=try newJob.answerContext()
        let contextText=String(data:try JSONSerialization.data(withJSONObject:context),encoding:.utf8)!
        precondition(contextText.contains("PRIVATE_SENTINEL") && contextText.contains("snapshot-new"))
        let wrong=ModelAnswer(text:"wrong",source_id:"other",model:"test-model",generated_at:"2030-09-28T12:00:00Z")
        rejects { try newJob.acceptAnswer(wrong) }
        let answer=ModelAnswer(text:"来自模型的真实回答",source_id:"snapshot-new",model:"test-model",generated_at:"2030-09-28T12:00:00Z")
        try newJob.acceptAnswer(answer);try newJob.acceptAnswer(answer)
        precondition(newJob.state=="query_complete" && newJob.answer?.text==answer.text)
        let changed=ModelAnswer(text:"不同回答",source_id:answer.source_id,model:answer.model,generated_at:answer.generated_at)
        rejects { try newJob.acceptAnswer(changed) }
        try store.save([newJob]);let withAnswer=try store.load()
        precondition(withAnswer[0].answer==answer && withAnswer[0].query_result_id=="snapshot-new")
        precondition(newJob.wire["queryResult"]==nil && newJob.wire["answer_context"]==nil)
        print("PASS model answer contract: explicit v5 scoped export, legacy denial, source binding, immutable/idempotent delivery, persisted answer.")
        print("PASS native query: overlap merging, half-open/all-day boundaries, DST 23/25-hour days, routing, private phone persistence vs RPC summary.")
    }
}
