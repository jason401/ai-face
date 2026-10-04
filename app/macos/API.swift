// Talks to the Python server (core/aiface/server.py) on 127.0.0.1.
import Foundation

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
            done?(false, ["message": "AI Face가 아직 시작 중이에요. 잠시 뒤 다시 해 주세요."])
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
                reply["message"] = err?.localizedDescription ?? "AI Face 서버에 연결하지 못했어요."
            }
            DispatchQueue.main.async { done?(code == 200, reply) }
        }.resume()
    }

    /// Adds an original picture to the photo library (POST /library).
    func addToLibrary(name: String, data: Data, done: @escaping (Bool, String) -> Void) {
        guard ready, let u = url("library") else { done(false, "AI Face가 아직 시작 중이에요."); return }
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
            if code == 0 { message = err?.localizedDescription ?? "저장하지 못했어요." }
            DispatchQueue.main.async { done(code == 200, message) }
        }.resume()
    }
}
