// Test-only stand-in. Production builds import Apple's EventKit, never this module.
import Foundation
public enum EKAuthorizationStatus { case notDetermined, restricted, denied, fullAccess, writeOnly }
public enum EKEntityType { case event }
public enum EKSpan { case thisEvent, futureEvents }
public enum EKAlarmProximity: Int { case none, enter, leave }
public final class EKCalendar { public var allowsContentModifications = true; public init() {} }
public final class EKAlarm {
    public var relativeOffset: TimeInterval = 0
    public var absoluteDate: Date?
    public var structuredLocation: String?
    public var proximity = EKAlarmProximity.none
    public init(relativeOffset: TimeInterval) { self.relativeOffset = relativeOffset }
    public init(absoluteDate: Date) { self.absoluteDate = absoluteDate }
}
public final class EKEvent {
    public var calendar: EKCalendar?
    public var title: String!
    public var location: String?
    public var startDate: Date!
    public var endDate: Date!
    public var timeZone: TimeZone?
    public var isAllDay = false
    public var alarms: [EKAlarm]?
    public var recurrenceRules: [EKRecurrenceRule]?
    public var url: URL?
    public var attendees: [String]?
    public var notes: String?
    public var eventIdentifier: String?
    public init(eventStore: EKEventStore) {}
}
public final class EKEventStore {
    public static var saves = 0
    public static var queries = 0
    public static var instances = 0
    public static var permission = EKAuthorizationStatus.fullAccess
    public static var events: [String: EKEvent] = [:]
    public static var readTransform: ((EKEvent) -> EKEvent?)?
    public static var beforeSave: (() throws -> Void)?
    public static var failAfterSave = false
    public var defaultCalendarForNewEvents: EKCalendar? = EKCalendar()
    public init() { Self.instances += 1 }
    public static func authorizationStatus(for type: EKEntityType) -> EKAuthorizationStatus { permission }
    public func requestFullAccessToEvents() async throws -> Bool { true }
    public func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        try Self.beforeSave?(); Self.saves += 1
        event.eventIdentifier = UUID().uuidString; Self.events[event.eventIdentifier!] = event
        if Self.failAfterSave { throw NSError(domain: "test", code: 1) }
    }
    public func event(withIdentifier id: String) -> EKEvent? {
        Self.queries += 1
        guard let e = Self.events[id] else { return nil }
        if let transform = Self.readTransform { return transform(e) }
        return e
    }
    public static func reset() { saves=0;queries=0;instances=0;events=[:];readTransform=nil;beforeSave=nil;failAfterSave=false;permission = .fullAccess }
}

public enum EKRecurrenceFrequency: Int { case daily, weekly, monthly, yearly }
public enum EKWeekday: Int { case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday }
public final class EKRecurrenceDayOfWeek {
    public let dayOfTheWeek: EKWeekday
    public let weekNumber = 0
    public init(_ day: EKWeekday) { dayOfTheWeek = day }
}
public final class EKRecurrenceEnd {
    public var occurrenceCount: Int
    public var endDate: Date?
    public init(occurrenceCount: Int) { self.occurrenceCount = occurrenceCount }
    public init(end: Date) { endDate = end; occurrenceCount = 0 }
}
public final class EKRecurrenceRule {
    public var frequency: EKRecurrenceFrequency
    public var interval: Int
    public var daysOfTheWeek: [EKRecurrenceDayOfWeek]?
    public var daysOfTheMonth: [NSNumber]?
    public var monthsOfTheYear: [NSNumber]?
    public var weeksOfTheYear: [NSNumber]?
    public var daysOfTheYear: [NSNumber]?
    public var setPositions: [NSNumber]?
    public var recurrenceEnd: EKRecurrenceEnd?
    public let firstDayOfTheWeek = 2
    public init(recurrenceWith frequency: EKRecurrenceFrequency, interval: Int,
        daysOfTheWeek: [EKRecurrenceDayOfWeek]?, daysOfTheMonth: [NSNumber]?, monthsOfTheYear: [NSNumber]?,
        weeksOfTheYear: [NSNumber]?, daysOfTheYear: [NSNumber]?, setPositions: [NSNumber]?, end: EKRecurrenceEnd?) {
        self.frequency = frequency; self.interval = interval; self.daysOfTheWeek = daysOfTheWeek
        self.daysOfTheMonth = daysOfTheMonth; self.monthsOfTheYear = monthsOfTheYear
        self.weeksOfTheYear = weeksOfTheYear; self.daysOfTheYear = daysOfTheYear; self.setPositions = setPositions; recurrenceEnd = end
    }
}
