import Foundation
import EventKit

@main struct FeatureValidation {
    static func main() throws {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        func recurrence(_ frequency: String = "weekly", days: [Int] = [5], monthDays: [Int] = [], months: [Int] = [], interval: Int = 1,
                        end: String = "never", count: Int? = nil, until: String? = nil) -> RecurrenceRequest {
            RecurrenceRequest(mode: "repeat", frequency: frequency, interval: interval, weekdays: days, month_days: monthDays,
                months: months, end_type: end, count: count, until: until, evidence: "每周五", reason: "测试")
        }
        let friday = ISO8601DateFormatter().date(from: "2030-01-04T09:00:00+08:00")!
        let weekly = recurrence(end: "count", count: 4)
        try weekly.validate(); try weekly.validateAnchor(start: friday, zone: zone)
        let rule = weekly.eventKitRule(zone: zone)!
        precondition(rule.frequency == .weekly && rule.daysOfTheWeek![0].dayOfTheWeek == .friday && rule.recurrenceEnd?.occurrenceCount == 4)
        precondition(weekly.matches([rule], zone: zone))
        precondition(!weekly.matches([], zone: zone))
        let until = recurrence(end: "until", until: "2030-01-04")
        try until.validateAnchor(start: friday, zone: zone)
        precondition(until.untilDate(zone: zone)! == ISO8601DateFormatter().date(from: "2030-01-04T23:59:59+08:00")!)
        let before = recurrence(end: "until", until: "2030-01-03")
        do { try before.validateAnchor(start: friday, zone: zone); fatalError("past until accepted") } catch {}
        do { try weekly.validateAnchor(start: friday.addingTimeInterval(86400), zone: zone); fatalError("wrong anchor weekday") } catch {}
        for r in [recurrence("daily",days:[]), recurrence(days:[2,4],interval:2), recurrence("monthly",days:[],monthDays:[-1]), recurrence("yearly",days:[],monthDays:[29],months:[2])] {
            try r.validate(); precondition(r.matches([r.eventKitRule(zone:zone)!], zone:zone))
        }
        let monthly = recurrence("monthly",days:[],monthDays:[-1])
        try monthly.validateAnchor(start: ISO8601DateFormatter().date(from:"2030-02-28T09:00:00+08:00")!,zone:zone)
        let none = RecurrenceRequest(mode:"none",frequency:nil,interval:1,weekdays:[],month_days:[],months:[],end_type:"never",count:nil,until:nil,evidence:nil,reason:"无重复")
        let features = CalendarFeatures(is_all_day:true,notes:"带书",url:"https://example.com",recurrence:none,reason:"全天",unsupported:[])
        try features.validate(text:"全天带书 https://example.com")
        let now = ISO8601DateFormatter().date(from:"2029-01-01T00:00:00Z")!
        var item: [String:Any] = ["item_id":"i1","title":"AgentX Test DST", "start_at":"2030-03-09T00:00:00-05:00", "end_at":"2030-03-12T00:00:00-04:00", "time_zone":"America/New_York", "calendar":features.wire]
        let validated = try CalendarEventInput(item,now:now,productMode:true)
        precondition(validated.end.timeIntervalSince(validated.start) == 71*3600) // local days, not 72h
        item["end_at"]="2030-03-12T01:00:00-04:00"
        do { _ = try CalendarEventInput(item,now:now,productMode:true); fatalError("nonmidnight all day") } catch {}
        item["calendar"] = CalendarFeatures(is_all_day:false,notes:nil,url:nil,recurrence:none,reason:"明确跨天",unsupported:[]).wire
        _ = try CalendarEventInput(item,now:now,productMode:true)
        item.removeValue(forKey:"calendar")
        do { _ = try CalendarEventInput(item,now:now,productMode:true); fatalError("legacy duration broadened") } catch {}
        let relative=AlertSpec(alert_id:"a1",trigger_type:"relative",offset_seconds:-3600,at:nil,source:"explicit",evidence:"提醒",reason:"测试")
        let absolute=AlertSpec(alert_id:"a2",trigger_type:"absolute",offset_seconds:nil,at:"2030-01-04T07:00:00+08:00",source:"explicit",evidence:"提醒",reason:"测试")
        let alerts=AlertRequest(mode:"explicit",evidence:"提醒",reason:"测试",count_limit:nil,no_extra:true,overflow:false,items:[relative,absolute])
        let evaluated=AlertPolicy.evaluate(alerts,start:friday,zone:zone,now:now,recurring:true)
        precondition(!evaluated.complete && evaluated.configured.count == 1 && evaluated.configured[0].type == "relative")
        print("PASS calendar capabilities: native rule mapping, recurrence ends/anchor, leap month, DST all-day/exclusive end, cross-day, legacy limits, recurring alert safety. No calendar writes.")
    }
}
