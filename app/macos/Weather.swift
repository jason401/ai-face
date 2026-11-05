import Cocoa
import SwiftUI

extension SettingsStore {
    static var weatherDateFormat: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    func loadWeather() {
        API.shared.getJSON("weather") { [weak self] json in
            guard let self, let state = json as? [String: Any], let c = state["config"] as? [String: Any] else { return }
            if !self.weatherLoaded {
                self.weatherEnabled = c["enabled"] as? Bool ?? true
                self.weatherMode = c["mode"] as? String ?? "auto"
                self.weatherHour = c["hour"] as? Int ?? 20
                self.weatherLocation = c["location"] as? [String: Any] ?? [:]
                if let text = c["date"] as? String, let date = Self.weatherDateFormat.date(from: text) {
                    self.weatherDate = date
                } else {
                    let local = DateFormatter()
                    local.locale = Locale(identifier: "en_US_POSIX")
                    local.timeZone = TimeZone(identifier: self.weatherLocation["timezone"] as? String ?? "America/Los_Angeles")
                    local.dateFormat = "yyyy-MM-dd"
                    self.weatherDate = Self.weatherDateFormat.date(from: local.string(from: Date())) ?? Date()
                }
                self.weatherLoaded = true
            }
            let message = state["message"] as? String ?? ""
            let source = state["source"] as? String ?? ""
            let names = ["current": L("Current model estimate"), "forecast": L("Forecast"),
                         "recent": L("Recent model data"), "historical": L("Historical reanalysis")]
            let scene = state["scene"] as? [String: Any] ?? [:]
            let conditions = [L("Clear"), L("Partly cloudy"), L("Overcast"), L("Rain"), L("Snow"), L("Fog")]
            let kind = scene["kind"] as? Int ?? -1
            var pieces: [String] = []
            if state["loading"] as? Bool == true { pieces.append(L("Loading weather…")) }
            if let name = names[source] { pieces.append(name) }
            if conditions.indices.contains(kind) { pieces.append(conditions[kind]) }
            if let sample = state["sample"] as? String, !sample.isEmpty { pieces.append(sample) }
            if !message.isEmpty { pieces.append(message) }
            if c["enabled"] as? Bool == false { pieces.append(L("Weather effects off.")) }
            else if scene["active"] as? Bool != true { pieces.append(L("Showing the original campfire until weather is available.")) }
            if state["board_supported"] as? Bool == false { pieces.append(L("Update board firmware to show weather on the display.")) }
            self.weatherDetail = pieces.joined(separator: " · ")
        }
    }

    func saveWeather(showFire: Bool = false) {
        guard !weatherLocation.isEmpty else { return }
        let c: [String: Any] = ["enabled": weatherEnabled, "mode": weatherMode,
                               "date": Self.weatherDateFormat.string(from: weatherDate),
                               "hour": weatherHour, "location": weatherLocation]
        API.shared.post("weather", c) { [weak self] ok, reply in
            self?.weatherNotice = ok ? "" : (reply["message"] as? String ?? L("Could not save weather settings."))
            self?.loadWeather()
            if ok && showFire { API.shared.call("mode", ["mode": "FIRE"]) }
        }
    }

    func searchWeatherLocation() {
        let query = weatherQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { weatherNotice = L("Enter at least two characters."); return }
        weatherSearching = true
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+#?="))) ?? ""
        API.shared.get("weather/locations?q=" + encoded, timeout: 20) { [weak self] data in
            guard let self else { return }
            self.weatherSearching = false
            guard self.weatherQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            guard let data, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let locations = reply["locations"] as? [[String: Any]] else {
                self.weatherNotice = L("Location search failed. Try again."); return
            }
            self.weatherLocations = locations
            self.weatherNotice = locations.isEmpty ? L("No matching city found.") : ""
        }
    }
}

struct CampfireWeatherCard: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        SettingsCard(title: L("Campfire weather")) {
            SettingsRow(title: L("Weather")) {
                SettingsSwitch(title: L("Use local weather"), isOn: Binding(get: { store.weatherEnabled }, set: { store.weatherEnabled = $0; store.saveWeather() }))
            }
            Divider()
            SettingsNote(text: (store.weatherLocation["name"] as? String) ?? "Palo Alto / Stanford", lines: 2)
            SettingsRow(title: L("Change place")) {
                TextField(L("City or postal code"), text: $store.weatherQuery).textFieldStyle(.roundedBorder)
                    .onSubmit { store.searchWeatherLocation() }
                SettingsAction(title: L("Search")) { store.searchWeatherLocation() }.disabled(store.weatherSearching)
                    .frame(width: 56)
            }
            ForEach(store.weatherLocations.indices, id: \.self) { index in
                Button(store.weatherLocations[index]["name"] as? String ?? "") {
                    store.weatherLocation = store.weatherLocations[index]
                    store.weatherLocations = []
                    store.saveWeather()
                }.font(.caption).buttonStyle(.link).lineLimit(2)
            }
            Divider()
            SettingsRow(title: L("Show weather")) {
                SettingsMenu(options: [(L("Automatic"), "auto"), (L("Selected date"), "date")],
                             selection: Binding(get: { store.weatherMode }, set: { store.weatherMode = $0; if $0 == "auto" { store.saveWeather() } }))
            }
            if store.weatherMode == "date" {
                SettingsRow(title: L("Date")) {
                    DatePicker(L("Date"), selection: $store.weatherDate, displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .datePickerStyle(.field).labelsHidden()
                }
                SettingsRow(title: L("Local hour")) {
                    SettingsMenu(options: (0..<24).map { (String(format: "%02d:00", $0), $0) }, selection: $store.weatherHour)
                    SettingsAction(title: L("Show this time")) { store.saveWeather(showFire: true) }
                }
                SettingsNote(text: L("Time at the selected city. Past dates use model history; future dates use forecasts up to 15 days ahead."), lines: 3)
            }
            if !store.weatherNotice.isEmpty { SettingsNote(text: store.weatherNotice, lines: 3) }
            SettingsNote(text: store.weatherDetail, lines: 5).help(store.weatherDetail)
            Link("Weather: Open-Meteo · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!)
                .font(.caption2)
        }
    }
}
