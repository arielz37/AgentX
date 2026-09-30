// Test-only stand-in. Production builds import Apple's EventKit, never this module.
import Foundation
public enum EKAuthorizationStatus { case notDetermined, restricted, denied, fullAccess, writeOnly }
public enum EKEntityType { case event }
public enum EKSpan { case thisEvent, futureEvents }
public enum EKAlarmProximity: Int { case none, enter, leave }
public enum EKEventStatus: Int { case none, confirmed, tentative, canceled }
public enum EKEventAvailability: Int { case notSupported, busy, free, tentative, unavailable }
public enum EKCalendarType { case local, calDAV, exchange, subscription, birthday }
public final class EKCalendar {
    public var title = "Synthetic Calendar"
    public var allowsContentModifications = true
    public var calendarIdentifier = UUID().uuidString
    public var isSubscribed = false
    public var type = EKCalendarType.local
    public init() {}
}
public final class EKAlarm {
    public var relativeOffset: TimeInterval = 0
    public var absoluteDate: Date?
    public var structuredLocation: String?
    public var proximity = EKAlarmProximity.none
    public init(relativeOffset: TimeInterval) { self.relativeOffset = relativeOffset }
    public init(absoluteDate: Date) { self.absoluteDate = absoluteDate }
}
public final class EKEvent {
    public var lastModifiedDate: Date?
    public var status = EKEventStatus.confirmed
    public var availability = EKEventAvailability.busy
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
    // Fault injection: model expensive per-store connections and a stale cache.
    public static var instanceLimit: Int?
    public static var resetCalls = 0
    public static var cacheReads = false
    public static var writtenStoreIDs: Set<Int> = []
    public static var queriedStoreIDs: Set<Int> = []
    private let instanceID: Int
    private var cachedEvents: [EKEvent]?
    public static var rangeQueries = 0
    public static var calendarList: [EKCalendar] = [EKCalendar()]
    public static var rangeEvents: [EKEvent]?
    public static var removes = 0
    public static var copyReadEvents = false
    public static var saves = 0
    public static var queries = 0
    public static var instances = 0
    public static var permission = EKAuthorizationStatus.fullAccess
    public static var events: [String: EKEvent] = [:]
    public static var readTransform: ((EKEvent) -> EKEvent?)?
    public static var beforeSave: (() throws -> Void)?
    public static var failAfterSave = false
    public var defaultCalendarForNewEvents: EKCalendar? = EKCalendar()
    public init() { Self.instances += 1; instanceID = Self.instances }
    private var available: Bool { Self.instanceLimit.map { instanceID <= $0 } ?? true }
    public func reset() { Self.resetCalls += 1; cachedEvents = nil }
    public static func authorizationStatus(for type: EKEntityType) -> EKAuthorizationStatus { permission }
    public func requestFullAccessToEvents() async throws -> Bool { true }
    public func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        try Self.beforeSave?(); Self.saves += 1; Self.writtenStoreIDs.insert(instanceID)
        event.eventIdentifier = event.eventIdentifier ?? UUID().uuidString; Self.events[event.eventIdentifier!] = event
        if Self.failAfterSave { throw NSError(domain: "test", code: 1) }
    }
    public func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws {
        try Self.beforeSave?(); Self.removes += 1
        if let id = event.eventIdentifier { Self.events.removeValue(forKey: id) }
        if Self.failAfterSave { throw NSError(domain: "test", code: 2) }
    }
    private func clone(_ e: EKEvent) -> EKEvent {
        let c=EKEvent(eventStore:self);c.status=e.status;c.availability=e.availability;c.calendar=e.calendar
        c.title=e.title;c.location=e.location;c.startDate=e.startDate;c.endDate=e.endDate;c.timeZone=e.timeZone
        c.isAllDay=e.isAllDay;c.alarms=e.alarms;c.recurrenceRules=e.recurrenceRules;c.url=e.url;c.attendees=e.attendees
        c.notes=e.notes;c.eventIdentifier=e.eventIdentifier;c.lastModifiedDate=e.lastModifiedDate;return c
    }
    public func calendars(for type: EKEntityType) -> [EKCalendar] { available ? Self.calendarList : [] }
    private func readEvents() -> [EKEvent] {
        guard available else { return [] }
        let live = Self.rangeEvents ?? Array(Self.events.values)
        if !Self.cacheReads { return live }
        if cachedEvents == nil { cachedEvents = live.map { clone($0) } }
        return cachedEvents!
    }
    public func predicateForEvents(withStart start: Date, end: Date, calendars: [EKCalendar]?) -> NSPredicate {
        NSPredicate { value, _ in
            guard let e = value as? EKEvent, let a = e.startDate, let b = e.endDate else { return true }
            return a == b ? (a >= start && a < end) : (a < end && b > start)
        }
    }
    public func events(matching predicate: NSPredicate) -> [EKEvent] {
        Self.rangeQueries += 1; Self.queriedStoreIDs.insert(instanceID)
        return readEvents().filter { predicate.evaluate(with: $0) }.map { Self.copyReadEvents ? clone($0) : $0 }
    }
    public func event(withIdentifier id: String) -> EKEvent? {
        Self.queries += 1; Self.queriedStoreIDs.insert(instanceID)
        guard let e = readEvents().first(where: { $0.eventIdentifier == id }) else { return nil }
        if let transform = Self.readTransform { return transform(e) }
        return Self.copyReadEvents ? clone(e) : e
    }
    public static func reset() { instanceLimit=nil;resetCalls=0;cacheReads=false;writtenStoreIDs=[];queriedStoreIDs=[];copyReadEvents=false;removes=0;rangeQueries=0;calendarList=[EKCalendar()];rangeEvents=nil;saves=0;queries=0;instances=0;events=[:];readTransform=nil;beforeSave=nil;failAfterSave=false;permission = .fullAccess }
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
