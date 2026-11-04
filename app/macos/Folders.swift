// Shared folders (core/aiface/folder_access.py holds the list and the rules). Two parts:
// - FolderBookmarks: remembers each folder with a macOS bookmark, so a folder that was moved or
//   renamed is found again (Python cannot read bookmarks).
// - FolderCLI: `AIFace --pdf FILE FIRST LAST` prints a PDF's page text as JSON (PDFKit) for the
//   server, the same way `--mail` and `--calendar` answer one question and exit.
import Cocoa
import PDFKit

struct SharedFolder: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let on: Bool
    let missing: Bool
    let last: String        // "Read by Claude · 5 min ago"
    let bookmark: String

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String, let path = d["path"] as? String else { return nil }
        self.id = id
        self.name = name
        self.path = path
        on = (d["on"] as? Bool) ?? true
        missing = (d["missing"] as? Bool) ?? false
        last = (d["last"] as? String) ?? ""
        bookmark = (d["bookmark"] as? String) ?? ""
    }

    init(id: String, name: String, path: String, on: Bool = true, missing: Bool = false, last: String = "") {
        self.id = id; self.name = name; self.path = path; self.on = on; self.missing = missing; self.last = last
        bookmark = ""
    }

    /// The path with ~ for the home folder, for one gray line.
    var shortPath: String { return (path as NSString).abbreviatingWithTildeInPath }
}

enum FolderBookmarks {
    static func make(_ url: URL) -> String? {
        return (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString()
    }

    /// Folders that went missing but whose bookmark points to a folder that exists now: tell the
    /// server where they are. `done` runs when there was something to fix.
    static func relocateMoved(_ folders: [SharedFolder], done: @escaping () -> Void) {
        var pending = 0
        for f in folders where f.missing && !f.bookmark.isEmpty {
            guard let data = Data(base64Encoded: f.bookmark) else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.path != f.path else { continue }
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue else { continue }
            pending += 1
            var body: [String: Any] = ["op": "relocate", "id": f.id, "path": url.path]
            if let fresh = make(url) { body["bookmark"] = fresh }
            API.shared.post("folders", body) { _, _ in
                pending -= 1
                if pending == 0 { done() }
            }
        }
    }
}

enum FolderCLI {
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 3, let first = Int(args[1]), let last = Int(args[2]), first >= 1, last >= first else {
            return output(["error": "usage: --pdf FILE FIRST LAST"])
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: args[0])) else { return output(["error": "cannot open"]) }
        if doc.isLocked { return output(["error": "locked (password protected)"]) }
        var pages: [[String: Any]] = []
        if first <= doc.pageCount {
            for n in first...min(last, doc.pageCount) {
                pages.append(["page": n, "text": doc.page(at: n - 1)?.string ?? ""])
            }
        }
        return output(["page_count": doc.pageCount, "pages": pages])
    }

    static func output(_ object: Any) -> Int32 {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return 1 }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        return 0
    }
}
