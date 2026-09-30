import Foundation
import EventKit
@main struct RecurrenceConflicts {
    @MainActor static func main() throws {
        func date(_ s:String)->Date { ISO8601DateFormatter().date(from:s)! }
        EKEventStore.reset()
        let rule=RecurrenceRequest(mode:"repeat",frequency:"weekly",interval:1,weekdays:[1],month_days:[],months:[],end_type:"count",count:4,until:nil,evidence:"每周一",reason:"synthetic")
        let features=CalendarFeatures(is_all_day:false,notes:nil,url:nil,recurrence:rule,reason:"synthetic",unsupported:[])
        var data:[String:Any]=["item_id":"i1","title":"AgentX Test series","start_at":"2030-09-30T09:00:00+08:00","end_at":"2030-09-30T10:00:00+08:00","time_zone":"Asia/Shanghai","calendar":try JSONSerialization.jsonObject(with:JSONEncoder().encode(features))]
        let input=try CalendarEventInput(data,productMode:true)
        let e=EKEvent(eventStore:EKEventStore());e.calendar=EKEventStore.calendarList[0];e.title="synthetic PRIVATE";e.startDate=date("2030-10-07T09:00:00+08:00");e.endDate=e.startDate.addingTimeInterval(3600);EKEventStore.rangeEvents=[e]
        let result=try CalendarReader().comprehensiveConflicts(input)
        precondition(result["status"] as? String=="conflict" && result["occurrences_checked"] as? Int==4 && result["coverage"] as? String=="full_series")
        let raw=String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!;precondition(!raw.contains("PRIVATE"))
        e.availability = .free
        let clear=try CalendarReader().comprehensiveConflicts(input);precondition(clear["status"] as? String=="clear")
        e.availability = .busy;e.startDate=date("2030-10-07T10:00:00+08:00");e.endDate=e.startDate.addingTimeInterval(3600)
        let adjacent=try CalendarReader().comprehensiveConflicts(input);precondition(adjacent["status"] as? String=="clear")
        data["end_at"]="2030-10-08T10:00:00+08:00";EKEventStore.rangeEvents=[]
        let selfOverlap=try CalendarReader().comprehensiveConflicts(CalendarEventInput(data,productMode:true))
        precondition(selfOverlap["status"] as? String=="conflict")
        print("PASS recurring conflict TEST DOUBLE: later occurrence blocks, entire finite series coverage, free exclusion, half-open adjacency, self-overlapping series rejection, no private titles exposed.")
    }
}
