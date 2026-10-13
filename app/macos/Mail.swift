// Mail reading (the Mail app, through Apple events), read only. Two parts, like Calendar.swift:
// - MailAccess: the macOS "AI Face may control Mail" permission, asked from the settings window.
// - MailCLI: `AIFace --mail <command>` prints JSON and exits. The Python server runs this for
//   the AIs (core/aiface/mail_access.py); being the app binary started by the app, the Apple
//   events count as AI Face's. The scripts here only read: no sending, moving, deleting or
//   marking as read (reading `content` does not mark a message read).
import Cocoa

enum MailAccess {
    static let bundleID = "com.apple.mail"

    static var running: Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// allowed / notDetermined / denied / notRunning / unknown. ask = show the macOS question
    /// (blocks until the user answers; not on the main thread).
    static func status(ask: Bool = false) -> String {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return "unknown" }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) {
        case noErr: return "allowed"
        case -1744: return "notDetermined"   // errAEEventWouldRequireUserConsent
        case -1743: return "denied"          // errAEEventNotPermitted
        case -600: return "notRunning"       // procNotFound
        default: return "unknown"
        }
    }

    /// Opens Mail in the background (hidden) and waits until it runs.
    static func launch(timeout: Double = 20) -> Bool {
        if running { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        let end = Date().addingTimeInterval(timeout)
        while !running && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if running { Thread.sleep(forTimeInterval: 1.5) }   // let it answer Apple events
        return running
    }

    /// From the settings window: open Mail if needed, then ask macOS (on a background queue).
    static func request(_ done: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            _ = launch()
            let result = status(ask: true)
            DispatchQueue.main.async { done(result) }
        }
    }
}

enum MailCLI {
    static func output(_ object: Any) -> Int32 {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return 1 }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        return 0
    }

    /// A string as an AppleScript literal.
    static func quote(_ s: String) -> String {
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func run(script: String) -> (NSAppleEventDescriptor?, String?) {
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let e = error {
            return (nil, ((e[NSAppleScript.errorNumber] as? NSNumber)?.stringValue ?? "") + " "
                    + ((e[NSAppleScript.errorMessage] as? String) ?? ""))
        }
        return (result, nil)
    }

    static func list(_ d: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
        guard let d = d, d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    static func strings(_ d: NSAppleEventDescriptor?) -> [String] {
        return list(d).compactMap { $0.stringValue }
    }

    // Every message in every account's inbox ("mailboxes of inbox"), as lists per property. Variable
    // names carry an "m" prefix: plain words like "dates" are Mail terms inside the tell block.
    static func messagesScript(hidden: [String]) -> String {
        return """
        tell application "Mail"
            set hiddenNames to {\(hidden.map(quote).joined(separator: ", "))}
            set out to {}
            repeat with mb in (mailboxes of inbox)
                set acct to ""
                try
                    set acct to name of account of mb
                end try
                if hiddenNames does not contain acct then
                    -- "every message" is fast (a few seconds for 12,000 messages); "whose" searches and
                    -- ranges like "messages 1 thru 50" are many times slower. Old ones are dropped in Swift.
                    set mIds to id of every message of mb
                    set mSubs to subject of every message of mb
                    set mFroms to sender of every message of mb
                    set mDates to date received of every message of mb
                    set mSeen to read status of every message of mb
                    set mFlags to flagged status of every message of mb
                    set c to count of mIds
                    if (count of mSubs) = c and (count of mFroms) = c and (count of mDates) = c and (count of mSeen) = c and (count of mFlags) = c then
                        set end of out to {acct, mIds, mSubs, mFroms, mDates, mSeen, mFlags}
                    else
                        -- mail arrived in between: the lists do not line up
                        set end of out to {acct, {}, {}, {}, {}, {}, {}, "shifted"}
                    end if
                end if
            end repeat
            return out
        end tell
        """
    }

    static func readScript(account: String, id: Int) -> String {
        return """
        tell application "Mail"
            repeat with mb in (mailboxes of inbox)
                set acct to ""
                try
                    set acct to name of account of mb
                end try
                if acct is \(quote(account)) then
                    set m to (first message of mb whose id is \(id))
                    set attNames to {}
                    try
                        set attNames to name of every mail attachment of m
                    end try
                    return {subject of m, sender of m, date received of m, address of to recipients of m, address of cc recipients of m, content of m, attNames}
                end if
            end repeat
            error "not_found" number 404
        end tell
        """
    }

    static func prepare() -> String? {
        if !MailAccess.launch() { return "no_mail" }
        let s = MailAccess.status()
        return s == "allowed" ? nil : "no_access"
    }

    /// status | accounts | messages <days> [hidden accounts as JSON on stdin] | read <account> <id>
    static func run(_ args: [String]) -> Int32 {
        let command = args.first ?? ""
        if command == "status" {
            return output(["status": MailAccess.running ? MailAccess.status() : "notRunning"])
        }
        if let problem = prepare() { return output(["error": problem]) }
        switch command {
        case "accounts":
            let (r, err) = run(script: "tell application \"Mail\" to return {name of every account, enabled of every account}")
            if let err = err { return output(["error": "script", "message": err]) }
            let names = strings(r?.atIndex(1))
            let enabled = list(r?.atIndex(2)).map { $0.booleanValue }
            return output(names.enumerated().map { i, n in
                ["name": n, "enabled": i < enabled.count ? enabled[i] : true] as [String: Any]
            })
        case "messages":
            guard args.count >= 2, let days = Int(args[1]), (1...93).contains(days) else {
                return output(["error": "bad_range"])
            }
            let stdin = FileHandle.standardInput.readDataToEndOfFile()
            let hidden = ((try? JSONSerialization.jsonObject(with: stdin)) as? [String]) ?? []
            // Each property is a separate query: if mail arrived in between, ask once more.
            let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
            var boxes: [NSAppleEventDescriptor] = []
            for _ in 0..<2 {
                let (r, err) = run(script: messagesScript(hidden: hidden))
                if let err = err { return output(["error": "script", "message": err]) }
                boxes = list(r)
                if !boxes.contains(where: { $0.numberOfItems > 7 }) { break }
            }
            var out: [[String: Any]] = []
            for box in boxes {
                let acct = box.atIndex(1)?.stringValue ?? ""
                let ids = list(box.atIndex(2)), subs = list(box.atIndex(3)), froms = list(box.atIndex(4))
                let dates = list(box.atIndex(5)), seen = list(box.atIndex(6)), flags = list(box.atIndex(7))
                if [subs, froms, dates, seen, flags].contains(where: { $0.count != ids.count }) { continue }
                for i in 0..<ids.count {
                    let date = dates[i].dateValue?.timeIntervalSince1970 ?? 0
                    if date < cutoff { continue }
                    out.append([
                        "account": acct,
                        "id": Int(ids[i].int32Value),
                        "subject": i < subs.count ? (subs[i].stringValue ?? "") : "",
                        "from": i < froms.count ? (froms[i].stringValue ?? "") : "",
                        "date": date,
                        "read": i < seen.count ? seen[i].booleanValue : true,
                        "flagged": i < flags.count ? flags[i].booleanValue : false,
                    ])
                }
            }
            out.sort { (($0["date"] as? Double) ?? 0) > (($1["date"] as? Double) ?? 0) }
            return output(Array(out.prefix(1000)))
        case "read":
            guard args.count >= 3, let id = Int(args[2]) else { return output(["error": "usage"]) }
            let (r, err) = run(script: readScript(account: args[1], id: id))
            if let err = err {
                return output(["error": err.hasPrefix("404") || err.contains("-1719") || err.contains("-1728")
                               ? "not_found" : "script", "message": err])
            }
            guard let m = r else { return output(["error": "not_found"]) }
            return output([
                "subject": m.atIndex(1)?.stringValue ?? "",
                "from": m.atIndex(2)?.stringValue ?? "",
                "date": m.atIndex(3)?.dateValue?.timeIntervalSince1970 ?? 0,
                "to": strings(m.atIndex(4)),
                "cc": strings(m.atIndex(5)),
                "text": String((m.atIndex(6)?.stringValue ?? "").prefix(40000)),
                "attachments": strings(m.atIndex(7)),
            ])
        default:
            return output(["error": "usage: --mail status | accounts | messages DAYS (hidden JSON on stdin) | read ACCOUNT ID"])
        }
    }
}
