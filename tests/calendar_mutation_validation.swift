import Foundation
import EventKit
@main struct MutationValidation {
    @MainActor static func main() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        func date(_ s:String)->Date { ISO8601DateFormatter().date(from:s)! }
        let q=CalendarQuery(mode:"events",start_at:"2030-10-01T00:00:00+08:00",end_at:"2030-10-02T00:00:00+08:00",time_zone:"Asia/Shanghai",duration_minutes:60,day_start_minute:0,day_end_minute:1440,assumptions:[])
        func seed(_ id:String="one",_ hour:Int=9)->EKEvent {
            let e=EKEvent(eventStore:EKEventStore());e.eventIdentifier=id;e.title="AgentX Test synthetic"
            e.startDate=date("2030-10-01T00:00:00+08:00").addingTimeInterval(Double(hour)*3600);e.endDate=e.startDate.addingTimeInterval(3600)
            e.calendar=EKEventStore.calendarList[0];e.notes="preserved";EKEventStore.events[id]=e;return e
        }
        func engine(_ name:String)->CalendarMutator { let m=CalendarMutator(ledgerURL:folder.appendingPathComponent(name));m.mayWrite={true};return m }
        func decision(_ s:MutationSnapshot,_ op:String="update",_ patch:EventPatch?=EventPatch(notes:"changed"))->MutationDecision {
            .init(source_id:s.source_id,decision:"execute",message:"准备执行",actions:[.init(item_id:"i1",target_ref:s.candidates[0].target_ref,operation:op,scope:"this_event",patch:patch)])
        }
        func item(_ r:[String:Any])->[String:Any] { (r["items"] as! [[String:Any]])[0] }
        EKEventStore.reset();EKEventStore.copyReadEvents=true;_=seed()
        let m=engine("first"),source=try m.read(q),d=decision(source)
        let context=String(data:try JSONSerialization.data(withJSONObject:source.context),encoding:.utf8)!
        precondition(!context.contains("event_id") && !context.contains("fingerprint"))
        let r=try m.execute(taskID:"a",decision:d,source:source,testMode:true)
        precondition(item(r)["status"] as? String=="verified" && EKEventStore.saves==1)
        precondition(EKEventStore.events["one"]!.timeZone==nil && EKEventStore.events["one"]!.notes=="changed")
        let replay=try engine("first").execute(taskID:"a",decision:d,source:source,testMode:true)
        precondition(item(replay)["deduplicated"] as? Bool==true && EKEventStore.saves==1)
        let stale=try m.execute(taskID:"stale",decision:d,source:source,testMode:true)
        precondition(item(stale)["save_status"] as? String=="not_attempted" && EKEventStore.saves==1)
        let current=try m.read(q)
        let shift=decision(current,"update",EventPatch(start_at:"2030-10-01T09:30:00+08:00",end_at:"2030-10-01T10:30:00+08:00"))
        let moved=try m.execute(taskID:"move",decision:shift,source:current,testMode:true)
        precondition(item(moved)["status"] as? String=="verified") // overlapping itself is fine
        _=seed("other",11)
        let next=try m.read(q)
        let collision=decision(next,"update",EventPatch(start_at:"2030-10-01T11:00:00+08:00",end_at:"2030-10-01T12:00:00+08:00"))
        let blocked=try m.execute(taskID:"collision",decision:collision,source:next,testMode:true)
        precondition(item(blocked)["save_status"] as? String=="not_attempted")
        precondition(EKEventStore.events["one"]!.startDate==date("2030-10-01T09:30:00+08:00"))
        let removal=try m.read(q),remove=decision(removal,"delete",nil)
        let deleted=try m.execute(taskID:"delete",decision:remove,source:removal,testMode:true)
        precondition(item(deleted)["status"] as? String=="verified" && EKEventStore.removes==1 && EKEventStore.events["one"]==nil)
        _=try engine("first").execute(taskID:"delete",decision:remove,source:removal,testMode:true)
        precondition(EKEventStore.removes==1)
        EKEventStore.reset();EKEventStore.copyReadEvents=true;_=seed()
        let uncertain=engine("unknown"),s=try uncertain.read(q);EKEventStore.failAfterSave=true
        let action=decision(s)
        let unknown=try uncertain.execute(taskID:"u",decision:action,source:s,testMode:true)
        precondition(item(unknown)["status"] as? String=="unknown")
        _=try engine("unknown").execute(taskID:"u",decision:action,source:s,testMode:true)
        precondition(EKEventStore.saves==1)
        EKEventStore.reset();EKEventStore.copyReadEvents=true;let privateEvent=seed();privateEvent.title="Personal"
        let safe=engine("safety"),p=try safe.read(q)
        let denied=try safe.execute(taskID:"private",decision:decision(p,"delete",nil),source:p,testMode:true)
        precondition(item(denied)["save_status"] as? String=="not_attempted" && EKEventStore.removes==0)
        privateEvent.attendees=["invitee"]
        let invited=try safe.read(q);precondition(!invited.candidates[0].writable)
        var job=PlanJob(submission_id:"context",task_id:"context",version:7,text:"change",submitted_at:q.start_at,time_zone:q.time_zone,test_mode:true,state:"verified",message:"verified",lease_id:"lease",assistant_id:"calendar")
        job.resultData=try JSONSerialization.data(withJSONObject:r)
        precondition(job.conversationTurn.events.count==1)
        EKEventStore.reset();EKEventStore.copyReadEvents=true
        let allDay=seed();allDay.isAllDay=true;allDay.startDate=date(q.start_at);allDay.endDate=date(q.end_at).addingTimeInterval(-1);allDay.timeZone=nil
        let native=engine("all-day-native"),allSource=try native.read(q)
        precondition(allSource.candidates[0].end_at==q.end_at)
        let rename=decision(allSource,"update",EventPatch(title:"整理书房",notes:"先书架，再文件"))
        let renamed=try native.execute(taskID:"rename-day",decision:rename,source:allSource,testMode:true)
        precondition(item(renamed)["status"] as? String=="verified" && EKEventStore.events["one"]!.endDate==date(q.end_at).addingTimeInterval(-1))
        precondition(EKEventStore.events["one"]!.title=="AgentX Test 整理书房")
        // Manual move outside the old query range is resolved by the saved event identity.
        EKEventStore.events["one"]!.startDate=date("2030-10-04T00:00:00+08:00")
        EKEventStore.events["one"]!.endDate=date("2030-10-04T23:59:59+08:00")
        let link=ConversationLookup(history_ref:"prior/i1",event_id:"one")
        let movedOutside=try native.read(q,history:[link])
        precondition(movedOutside.candidates.count==1 && movedOutside.candidates[0].related_history_refs==["prior/i1"] && movedOutside.candidates[0].start_at=="2030-10-04T00:00:00+08:00")
        var boundQuery=q;boundQuery.target_history_refs=["different-history/i1"]
        let wrongSource=MutationSnapshot(source_id:movedOutside.source_id,queried_at:movedOutside.queried_at,query:boundQuery,candidates:movedOutside.candidates)
        do { try decision(wrongSource).validate(snapshot:wrongSource);fatalError("must not replace frozen historical target") } catch {}
        let latestRename=try native.execute(taskID:"manual-move-preserved",decision:decision(movedOutside,"update",EventPatch(notes:"new notes")),source:movedOutside,testMode:true)
        precondition(item(latestRename)["status"] as? String=="verified" && EKEventStore.events["one"]!.startDate==date("2030-10-04T00:00:00+08:00"))
        let beforeDelete=try native.read(q,history:[link]);EKEventStore.events.removeAll()
        let missing=try native.execute(taskID:"manual-delete",decision:decision(beforeDelete),source:beforeDelete,testMode:true)
        precondition(item(missing)["save_status"] as? String=="not_attempted" && EKEventStore.events.isEmpty)
        EKEventStore.reset();EKEventStore.copyReadEvents=true;_=seed()
        let outage=engine("delete-read-outage"),outageSource=try outage.read(q)
        EKEventStore.beforeSave={ EKEventStore.calendarList=[] }
        let unverified=try outage.execute(taskID:"delete-outage",decision:decision(outageSource,"delete",nil),source:outageSource,testMode:true)
        precondition(item(unverified)["save_status"] as? String=="saved" && item(unverified)["status"] as? String=="saved_unverified")
        precondition(item(unverified)["verification_status"] as? String != "verified")
        _=try outage.execute(taskID:"delete-outage",decision:decision(outageSource,"delete",nil),source:outageSource,testMode:true)
        precondition(EKEventStore.removes==1)
        print("PASS mutation EventKit TEST DOUBLE: minimal patch, self-exclusion, external conflict, stale fingerprint, delete readback, durable update/delete replay, unknown outcome no replay, test-mode/invitation guards, context actual results. No real writes.")
    }
}
