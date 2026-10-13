// Calendar reading (EventKit), read only. Two parts:
// - CalendarAccess: asks macOS for calendar access, from the settings window (the app itself,
//   so the permission belongs to "AI Face").
// - CalendarCLI: `AIFace --calendar <command>` prints JSON and exits, without starting the menu
//   bar app. The Python server runs this for the AIs; being the same app binary, it uses the
//   app's calendar permission. Nothing here can create, change or delete events.
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
            return output(calendars.map { cal -> [String: Any] in
                ["id": cal.calendarIdentifier, "title": cal.title, "account": cal.source.title,
                 "kind": sourceKind(cal)]
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
            return output(events.prefix(500).map { e -> [String: Any] in
                var item: [String: Any] = [
                    "title": e.title ?? "",
                    "start": e.startDate.timeIntervalSince1970,
                    "end": e.endDate.timeIntervalSince1970,
                    "all_day": e.isAllDay,
                    "location": e.location ?? "",
                    "calendar": e.calendar.title,
                    "calendar_id": e.calendar.calendarIdentifier,
                ]
                if details {   // only when the user turned this on in the settings
                    item["notes"] = String((e.notes ?? "").prefix(600))
                    item["attendees"] = (e.attendees ?? []).compactMap { $0.name }.prefix(20).map { $0 }
                }
                return item
            })
        default:
            return output(["error": "usage: --calendar status | calendars | events FROM TO [IDS|-] [details]"])
        }
    }
}
