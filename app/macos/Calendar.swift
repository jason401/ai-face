// Calendar reading (EventKit), read only. Two parts:
// - CalendarAccess: asks macOS for calendar access, from the settings window (the app itself,
//   so the permission belongs to "AI Face").
// - CalendarCLI: `AIFace --calendar <command>` prints JSON and exits, without starting the menu
//   bar app. The Python server runs this for the AIs; being the same app binary, it uses the
//   app's calendar permission. Writing (add / update / delete) is decided and confirmed in the
//   server (core/aiface/calendar_access.py); here, update and delete only touch events that
//   carry the AI Face tag in their notes (events added through AI Face).
import Foundation
import EventKit

enum CalendarAccess {
    /// notDetermined / restricted / denied / full / writeOnly (macOS 14 names; 13: full = authorized)
    static var status: String {
        switch EKEventStore.authorizationStatus(for: .event).rawValue {
        case 0: return "notDetermined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "full"
        case 4: return "writeOnly"
        default: return "unknown"
        }
    }

    static func request(_ done: @escaping (Bool) -> Void) {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in DispatchQueue.main.async { done(granted) } }
        } else {
            store.requestAccess(to: .event) { granted, _ in DispatchQueue.main.async { done(granted) } }
        }
    }
}

enum CalendarCLI {
    static let TAG = "— added by AI Face"

    static func input() -> [String: Any] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    static func ours(_ e: EKEvent) -> Bool {
        return (e.notes ?? "").contains(TAG)
    }

    static func userNotes(_ e: EKEvent) -> String {
        return (e.notes ?? "").replacingOccurrences(of: "\n\n" + TAG, with: "")
            .replacingOccurrences(of: TAG, with: "")
    }

    static func describe(_ e: EKEvent, details: Bool) -> [String: Any] {
        var item: [String: Any] = [
            "id": e.eventIdentifier ?? "",
            "title": e.title ?? "",
            "start": e.startDate.timeIntervalSince1970,
            "end": e.endDate.timeIntervalSince1970,
            "all_day": e.isAllDay,
            "location": e.location ?? "",
            "calendar": e.calendar.title,
            "calendar_id": e.calendar.calendarIdentifier,
            "ours": ours(e),
            "recurring": e.hasRecurrenceRules,
        ]
        if details {
            item["notes"] = String(userNotes(e).prefix(600))
            item["attendees"] = (e.attendees ?? []).compactMap { $0.name }.prefix(20).map { $0 }
        }
        return item
    }

    /// The event (one occurrence of a repeating one) with this id starting at `occurrence`.
    static func find(_ store: EKEventStore, _ id: String, _ occurrence: Double?) -> EKEvent? {
        guard let base = store.event(withIdentifier: id) else { return nil }
        guard base.hasRecurrenceRules, let at = occurrence else { return base }
        let day = Date(timeIntervalSince1970: at)
        let predicate = store.predicateForEvents(withStart: day.addingTimeInterval(-86400),
                                                 end: day.addingTimeInterval(86400), calendars: [base.calendar])
        return store.events(matching: predicate).first {
            $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince1970 - at) < 1
        } ?? base
    }

    static func apply(_ e: EKEvent, _ f: [String: Any]) {
        if let t = f["title"] as? String { e.title = t }
        if let a = f["all_day"] as? Bool { e.isAllDay = a }
        if let s = (f["start"] as? NSNumber)?.doubleValue { e.startDate = Date(timeIntervalSince1970: s) }
        if let x = (f["end"] as? NSNumber)?.doubleValue { e.endDate = Date(timeIntervalSince1970: x) }
        if let l = f["location"] as? String { e.location = l }
        if let n = f["notes"] as? String { e.notes = n.isEmpty ? TAG : n + "\n\n" + TAG }
    }

    /// add / update / delete; the change as JSON (stdin). Prints {event, before} or {error}.
    static func write(_ store: EKEventStore, _ command: String) -> Int32 {
        let f = input()
        do {
            switch command {
            case "add":
                guard let calId = f["calendar_id"] as? String, let cal = store.calendar(withIdentifier: calId),
                      cal.allowsContentModifications else { return output(["error": "calendar"]) }
                let e = EKEvent(eventStore: store)
                e.calendar = cal
                e.notes = TAG
                apply(e, f)
                try store.save(e, span: .thisEvent, commit: true)
                return output(["event": describe(e, details: true)])
            case "update", "delete":
                guard let id = f["id"] as? String,
                      let e = find(store, id, (f["occurrence"] as? NSNumber)?.doubleValue) else {
                    return output(["error": "not_found"])
                }
                guard ours(e) else { return output(["error": "not_ours"]) }
                let before = describe(e, details: true)
                if command == "delete" {
                    try store.remove(e, span: .thisEvent, commit: true)
                    return output(["before": before])
                }
                if let calId = f["calendar_id"] as? String {
                    guard let cal = store.calendar(withIdentifier: calId), cal.allowsContentModifications else {
                        return output(["error": "calendar"])
                    }
                    e.calendar = cal
                }
                apply(e, f)
                try store.save(e, span: .thisEvent, commit: true)
                return output(["before": before, "event": describe(e, details: true)])
            default:
                return output(["error": "usage"])
            }
        } catch {
            return output(["error": "save_failed", "message": error.localizedDescription])
        }
    }

    static func output(_ object: Any) -> Int32 {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return 1 }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        return 0
    }

    static func sourceKind(_ cal: EKCalendar) -> String {
        switch cal.source.sourceType {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "icloud"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "other"
        }
    }

    /// calendars | events <from-epoch> <to-epoch> [ids,comma,separated|-] [details] | status
    static func run(_ args: [String]) -> Int32 {
        let command = args.first ?? ""
        if command == "status" { return output(["status": CalendarAccess.status]) }
        guard CalendarAccess.status == "full" else {
            return output(["error": "no_access", "status": CalendarAccess.status])
        }
        let store = EKEventStore()
        let calendars = store.calendars(for: .event)
        switch command {
        case "calendars":
            let fallback = store.defaultCalendarForNewEvents?.calendarIdentifier ?? ""
            return output(calendars.map { cal -> [String: Any] in
                ["id": cal.calendarIdentifier, "title": cal.title, "account": cal.source.title,
                 "kind": sourceKind(cal), "writable": cal.allowsContentModifications,
                 "default": cal.calendarIdentifier == fallback]
            })
        case "events":
            guard args.count >= 3, let from = Double(args[1]), let to = Double(args[2]), to > from,
                  to - from <= 93 * 86400 else {
                return output(["error": "bad_range"])
            }
            let wanted = args.count >= 4 && args[3] != "-" ? Set(args[3].split(separator: ",").map(String.init)) : nil
            let details = args.count >= 5 && args[4] == "details"
            let chosen = wanted == nil ? calendars : calendars.filter { wanted!.contains($0.calendarIdentifier) }
            if chosen.isEmpty { return output([[String: Any]]()) }
            let predicate = store.predicateForEvents(withStart: Date(timeIntervalSince1970: from),
                                                     end: Date(timeIntervalSince1970: to), calendars: chosen)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            // notes and attendees only when the user turned them on in the settings
            return output(events.prefix(500).map { describe($0, details: details) })
        case "add", "update", "delete":
            return write(store, command)
        default:
            return output(["error": "usage: --calendar status | calendars | events FROM TO [IDS|-] [details] | add | update | delete"])
        }
    }
}
