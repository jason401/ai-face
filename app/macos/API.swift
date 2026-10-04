// Talks to the Python server (core/aiface/server.py) on 127.0.0.1.
import Foundation

/// The text for `key` (English) in the app's language: Resources/<lang>.lproj/Localizable.strings.
func L(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

/// The language the app shows (the first of the Mac's preferred languages it has), e.g. "en", "ko".
let APP_LANGUAGE = Bundle.main.preferredLocalizations.first ?? "en"
let APP_LOCALE = Locale(identifier: APP_LANGUAGE)

final class API {
    static let shared = API()
    var base: URL?          // http://127.0.0.1:<port>/
    var token = ""          // needed for POST

    var ready: Bool { return base != nil && !token.isEmpty }

    func url(_ path: String) -> URL? {
        guard let base = base else { return nil }
        return URL(string: path, relativeTo: base)
    }

    static func escape(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%;&+=")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    /// GET; `done` runs on the main thread with the body, or nil on any failure.
    func get(_ path: String, timeout: TimeInterval = 5, done: @escaping (Data?) -> Void) {
        guard let u = url(path) else { done(nil); return }
        let req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok ? data : nil) }
        }.resume()
    }

    func getJSON(_ path: String, done: @escaping (Any?) -> Void) {
        get(path) { data in
            guard let data = data else { done(nil); return }
            done(try? JSONSerialization.jsonObject(with: data, options: []))
        }
    }

    /// POST /api {action, ...}; `done(ok, reply)` on the main thread. The reply carries
    /// "message" (the result or the error, in Korean).
    func call(_ action: String, _ params: [String: Any] = [:], timeout: TimeInterval = 60,
              done: ((Bool, [String: Any]) -> Void)? = nil) {
        guard ready, let u = url("api") else {
            done?(false, ["message": L("AI Face is still starting. Try again in a moment.")])
            return
        }
        var body = params
        body["action"] = action
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-ESP-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var reply: [String: Any] = [:]
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                reply = json
            }
            if code == 0 {
                reply["message"] = err?.localizedDescription ?? L("Could not reach the AI Face server.")
            }
            DispatchQueue.main.async { done?(code == 200, reply) }
        }.resume()
    }

    /// Adds an original picture to the photo library (POST /library).
    func addToLibrary(name: String, data: Data, done: @escaping (Bool, String) -> Void) {
        guard ready, let u = url("library") else { done(false, L("AI Face is still starting.")); return }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-ESP-Token")
        req.setValue(API.escape(name), forHTTPHeaderField: "X-File-Name")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { body, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var message = ""
            if let body = body, let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] {
                message = (json["message"] as? String) ?? (json["name"] as? String) ?? ""
            }
            if code == 0 { message = err?.localizedDescription ?? L("Could not save it.") }
            DispatchQueue.main.async { done(code == 200, message) }
        }.resume()
    }
}
