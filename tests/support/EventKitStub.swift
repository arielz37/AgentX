// Test-only stand-in. Production builds import Apple's EventKit, never this module.
import Foundation
public enum EKAuthorizationStatus { case notDetermined, restricted, denied, fullAccess, writeOnly }
public enum EKEntityType { case event }
public enum EKSpan { case thisEvent }
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
    public var recurrenceRules: [String]?
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
