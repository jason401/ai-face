// The four settings tabs (일반 · AI · 보드 · 기록), built from the cards in SettingsKit.swift.
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General: the face, the app and its updates, keep awake

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    func bind<T>(_ path: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        return Binding(get: { store[keyPath: path] }, set: { store[keyPath: path] = $0; store.saveSaver() })
    }

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("Face")) {
                SettingsRow(title: L("Appearance")) {
                    Toggle(L("Monochrome"), isOn: Binding(get: { store.mono }, set: { store.setMono($0) }))
                        .toggleStyle(.checkbox)
                        .help(L("Draws the menu bar face in grays and shows who chose it by the ring pattern: you = solid, Claude = short dashes, GPT = six long arcs. The board always stays in color."))
                }
                Divider()
                SettingsRow(title: L("Screen saver")) {
                    SettingsMenu(options: SAVER_TYPES.map { ($0.label, $0.value) }, selection: bind(\.saverType))
                }
                Divider()
                SettingsRow(title: L("Wait")) {
                    SettingsMenu(options: store.afterChoices.map { (minutesText($0), $0) }, selection: bind(\.saverAfter))
                        .disabled(store.saverType == "off")
                }
                if store.saverType == "photo" || store.saverType == "slideshow" {
                    Divider()
                    SettingsRow(title: L("Photos")) {
                        Toggle(L("Clock hands over photos"), isOn: bind(\.saverClock)).toggleStyle(.checkbox)
                    }
                }
                if store.saverType == "slideshow" {
                    Divider()
                    SettingsRow(title: L("Change every")) {
                        SettingsMenu(options: store.slideChoices.map { ($0.label, $0.value) }, selection: bind(\.saverSlide))
                    }
                }
                SettingsNote(text: store.saverHint, lines: 3)
                    .help(store.saverHint + " " + L("A new face from an AI or the end of a timer brings the face back."))
            }
            SettingsCard(title: L("App")) {
                SettingsRow(title: L("Open at login")) {
                    SettingsSwitch(title: L("Open at login"), isOn: Binding(get: { store.loginItem }, set: { store.setLogin($0) }))
                        .help(L("The face appears in the menu bar as soon as you log in."))
                }
                Divider()
                SettingsRow(title: L("Auto check")) {
                    SettingsAction(title: L("Check now")) { store.checkUpdate() }
                        .disabled(store.updateRunning)
                    Toggle(L("Check for updates automatically"), isOn: Binding(get: { store.autoUpdate }, set: { store.setAutoUpdate($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .help(L("Check for updates automatically"))
                }
                if store.updateAvailable {
                    Divider()
                    SettingsRow(title: L("New version")) {
                        Button(action: { store.installUpdate() }) {
                            Text(L("Update now")).lineLimit(1).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                        }.buttonStyle(.plain)
                    }
                }
                SettingsNote(text: "AI Face " + store.version + "\n" + store.updateText, lines: 4)
                    .textSelection(.enabled)
                    .help(L("AI Face looks for a new stable version on GitHub at startup and every 3 hours, but installs it only when you click Update now (here or in the menu). It then tests and builds it in its own source folder and restarts. Your development folder is never changed. Existing Python and Command Line Tools are required."))
                Divider()
                SettingsRow(title: L("Folders")) {
                    SettingsAction(title: L("App data")) { store.openDataFolder() }
                        .help(L("Settings, photos, history, the update copy and backups"))
                    SettingsAction(title: L("App")) { store.revealApp() }
                        .help(Bundle.main.bundlePath)
                }
            }
            if store.awakeSupported {
                SettingsCard(title: L("Keep awake")) {
                    SettingsRow(title: L("Status")) {
                        SettingsStatus(text: store.awakeStatus, ok: store.awakeOn)
                    }
                    Divider()
                    SettingsRow(title: L("Permission")) {
                        SettingsAction(title: store.awakeReady ? L("Remove…") : L("Set up…")) { store.setUpAwake() }
                    }
                    if store.awakeReady {
                        Divider()
                        SettingsRow(title: L("awake command")) {
                            if store.awakeCommand {
                                SettingsStatus(text: L("Installed"))
                            } else {
                                SettingsAction(title: L("Install…")) { store.setUpAwake() }
                            }
                        }
                    }
                    SettingsNote(text: store.awakeNotice.isEmpty
                                 ? L("Lid closed, 1–4 hours from the menu. Turns off by itself.") : store.awakeNotice, lines: 3)
                        .help(L("Keeps the MacBook awake even with the lid closed, for 1, 2 or 4 hours (menu → Keep awake). It turns off at the end, at 20% battery, when the Mac gets hot, in Low Power Mode and when AI Face quits. Setting it up asks for your Mac password once, in Terminal, and allows only this one setting."))
                }
            }
        }
    }
}

// MARK: - AI: which apps show faces, and what they may read or change

struct AITab: View {
    @ObservedObject var store: SettingsStore

    func statusText(_ s: String) -> String {
        switch s {
        case "on": return L("Connected")
        case "other": return L("Connected to another location")
        case "error": return L("Cannot read its settings file")
        default: return L("Not connected")
        }
    }

    func appRow(_ title: String, _ status: String, _ target: String, available: Bool = true) -> some View {
        SettingsRow(title: title) {
            SettingsStatus(text: available ? statusText(status) : L("Not installed"), ok: status == "on")
                .help(available ? statusText(status) : L("Not installed"))
            if available {
                SettingsAction(title: status == "on" ? L("Disconnect") : L("Connect")) {
                    store.setAI(target, on: status != "on")
                }.frame(width: 68)
            }
        }
    }

    /// Two checkboxes, one per AI, for a read or write switch.
    func perAI(_ claude: Bool, _ gpt: Bool, _ set: @escaping (String, Bool) -> Void) -> some View {
        HStack(spacing: 14) {
            Toggle("Claude", isOn: Binding(get: { claude }, set: { set("claude", $0) }))
            Toggle("GPT", isOn: Binding(get: { gpt }, set: { set("gpt", $0) }))
        }.toggleStyle(.checkbox)
    }

    func accessRow(_ text: String, ok: Bool, busy: Bool = false, button: String?, _ action: @escaping () -> Void) -> some View {
        SettingsRow(title: L("Access")) {
            SettingsStatus(text: text, ok: ok)
            if busy {
                ProgressView().controlSize(.small)
            } else if let button = button {
                SettingsAction(title: button, action: action).fixedSize()
            }
        }
    }

    var calendarButton: String? {
        let a = store.calAccess
        if a == "full" || a == "" || a == "unavailable" { return nil }
        return a == "notDetermined" ? L("Allow…") : L("Open System Settings")
    }

    var mailButton: String? {
        let a = store.mailAccess
        if a == "allowed" || a == "" || a == "unavailable" { return nil }
        return a == "denied" ? L("Open System Settings") : L("Allow…")
    }

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("AI apps")) {
                appRow(L("Claude desktop"), store.claude, "claude")
                Divider()
                appRow("Codex (GPT)", store.codex, "codex", available: store.codexAvailable)
                Divider()
                appRow("Claude Code", store.claudeCode, "claude_code", available: store.claudeCodeAvailable)
                if store.awakeSupported {
                    Divider()
                    SettingsRow(title: L("Keep awake")) {
                        Toggle(L("While Claude Code works"), isOn: Binding(get: { store.hooks == "on" },
                                                                          set: { store.setAI("claude_code_awake", on: $0) }))
                            .toggleStyle(.checkbox).disabled(!store.awakeReady)
                            .help(L("Claude Code: keep the Mac awake while it works"))
                    }
                }
                SettingsNote(text: store.aiNotice.isEmpty ? L("After connecting or disconnecting, quit that app (⌘Q) and open it again.") : store.aiNotice, lines: 3)
                    .help(L("Once connected, the AI picks a face for every reply. After connecting or disconnecting, quit that app (⌘Q) and open it again. Ring colors: Claude orange, GPT green, your own picks white."))
            }

            SettingsCard(title: L("Calendar")) {
                accessRow(store.calAccessText, ok: store.calAccess == "full", button: calendarButton) { store.requestCalendarAccess() }
                Divider()
                SettingsRow(title: L("Can read")) {
                    perAI(store.calClaude, store.calGPT) { ai, on in store.setCalendar(["apps": [ai: on]]) }
                }
                Divider()
                SettingsRow(title: L("Can change")) {
                    perAI(store.calWriteClaude, store.calWriteGPT) { ai, on in store.setCalendar(["write_apps": [ai: on]]) }
                }
                Divider()
                SettingsRow(title: L("Details")) {
                    Toggle(L("Notes and attendees"), isOn: Binding(get: { store.calDetails }, set: { store.setCalendar(["details": $0]) }))
                        .toggleStyle(.checkbox)
                        .help(L("Include notes and attendees"))
                }
                Divider()
                SettingsRow(title: L("Ask first")) {
                    SettingsSwitch(title: L("Ask me before every change"), isOn: Binding(get: { store.calConfirm }, set: { store.setCalendar(["confirm": $0]) }))
                        .help(L("Ask me before every change"))
                }
                Divider()
                SettingsRow(title: L("Calendars")) {
                    SettingsAction(title: String(format: L("%d of %d on…"), store.calendars.filter { $0.shown }.count, store.calendars.count)) {
                        store.showCalendars = true
                    }
                    .disabled(store.calendars.isEmpty)
                    .popover(isPresented: $store.showCalendars, arrowEdge: .bottom) { CalendarList(store: store) }
                }
                if !store.calChanges.isEmpty {
                    Divider()
                    SettingsRow(title: L("Recent changes")) {
                        SettingsAction(title: String(format: L("%d changes…"), store.calChanges.count)) { store.showCalChanges = true }
                            .popover(isPresented: $store.showCalChanges, arrowEdge: .bottom) { CalendarChanges(store: store) }
                    }
                }
                SettingsNote(text: L("AIs change or delete only events they added. Every change can be undone."), lines: 3)
                    .help(L("Only the AIs you allow see the calendars you leave on: titles, times and places; notes and attendees only if you turn them on. After a change, quit that AI app (⌘Q) and open it again.")
                          + "\n\n" + L("AIs may add events to the calendars turned on here, and change or delete only events they added through AI Face; never anyone else's. With asking on, each change waits for your OK in a window. No invitations are sent."))
            }

            SettingsCard(title: L("Mail")) {
                accessRow(store.mailAccessText, ok: store.mailAccess == "allowed", busy: store.mailAsking,
                          button: mailButton) { store.requestMailAccess() }
                Divider()
                SettingsRow(title: L("Can read")) {
                    perAI(store.mailClaude, store.mailGPT) { ai, on in store.setMail(["apps": [ai: on]]) }
                }
                Divider()
                SettingsRow(title: L("Links")) {
                    Toggle(L("Hide links and codes"), isOn: Binding(get: { store.mailHideLinks }, set: { store.setMail(["hide_links": $0]) }))
                        .toggleStyle(.checkbox)
                }
                Divider()
                SettingsRow(title: L("Accounts")) {
                    SettingsAction(title: String(format: L("%d of %d on…"), store.mailAccounts.filter { $0.shown }.count, store.mailAccounts.count)) {
                        store.showMailAccounts = true
                    }
                    .disabled(store.mailAccounts.isEmpty)
                    .popover(isPresented: $store.showMailAccounts, arrowEdge: .bottom) { MailAccountList(store: store) }
                }
                SettingsNote(text: L("Read only: never sends, moves, deletes or marks mail as read."), lines: 2)
                    .help(L("AI Face reads the Mail app's inboxes. It never sends, moves or deletes mail, and does not mark it as read.")
                          + "\n\n" + L("Only the AIs you allow can read the accounts you leave on. With links and codes hidden, a link shows only its site and sign-in codes and passwords are left out. After a change, quit that AI app (⌘Q) and open it again."))
            }

            SettingsCard(title: L("Other apps")) {
                SettingsRow(title: L("Server command")) {
                    SettingsAction(title: L("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.otherAppCommand, forType: .string)
                    }
                }
                SettingsNote(text: store.otherAppCommand, lines: 3)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .onAppear { store.loadCalendar(); store.loadMail() }
    }
}

// MARK: - Board: connection, photos, firmware

struct BoardTab: View {
    // No @State: the Command Line Tools have no SwiftUI macro plugin, and the newest SDK
    // resolves @State to a macro. View state lives in the store instead.
    @ObservedObject var store: SettingsStore

    var statusText: String {
        store.connected ? L("Connected") : (store.ports.isEmpty ? L("Not connected") : L("Connecting or error"))
    }

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("ESP32 display")) {
                SettingsRow(title: L("Status")) {
                    SettingsStatus(text: statusText, ok: store.connected)
                    if !store.connected && !store.ports.isEmpty {
                        SettingsAction(title: L("Reconnect")) { store.reconnect() }.fixedSize()
                    }
                }
                if store.connected {
                    Divider()
                    SettingsRow(title: L("Port")) {
                        Text(store.port).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if !store.message.isEmpty {
                    SettingsNote(text: store.message, lines: 3).textSelection(.enabled)
                }
            }

            SettingsCard(title: L("Photos on the board") + "  \(store.photos.count)/10") {
                if !store.connected {
                    SettingsNote(text: L("They show up here when a board is connected."), lines: 2).padding(.top, 8)
                } else if store.photos.isEmpty {
                    SettingsNote(text: L("None yet. Click a photo in the library below to send it to the board."), lines: 2).padding(.top, 8)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.photos, id: \.self) { id in boardThumb(id) }
                        }
                        .padding(8)
                    }
                }
            }

            SettingsCard(title: L("Photo library") + "  " + String(format: L("%d photos"), store.library.count)) {
                SettingsRow(title: L("Add")) {
                    SettingsAction(title: L("Add photos…")) { store.choosePictures() }
                    SettingsAction(title: L("Show in Finder")) { store.openLibraryFolder() }
                }
                Divider()
                ZStack {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 8)], spacing: 8) {
                        ForEach(store.library) { item in libraryThumb(item) }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .top)
                    if store.library.isEmpty || store.dropping {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundStyle(store.dropping ? Color.accentColor : Color.secondary.opacity(0.5))
                            .overlay(Text(L("Drop pictures here")).foregroundStyle(.secondary))
                            .background(store.dropping ? Color.accentColor.opacity(0.08) : Color.clear)
                            .padding(8)
                    }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: $store.dropping) { providers in
                    var urls: [URL] = []
                    let group = DispatchGroup()
                    for provider in providers {
                        group.enter()
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let url = url { DispatchQueue.main.async { urls.append(url) } }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) { store.addPictures(urls) }
                    return true
                }
                SettingsNote(text: store.notice.isEmpty ? L("Click a photo to show it on the board. Right-click to delete.") : store.notice, lines: 2)
            }

            SettingsCard(title: L("Firmware")) {
                SettingsRow(title: L("Update")) {
                    SettingsAction(title: L("Update firmware")) { store.updateFirmware() }
                        .disabled(store.ports.isEmpty || store.firmwareBusy || store.flashing)
                    if store.firmwareBusy || store.flashing {
                        ProgressView().controlSize(.small)
                    }
                }
                if !store.firmwareLog.isEmpty {
                    ScrollView {
                        Text(store.firmwareLog)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                    .padding(.horizontal, 10)
                }
                SettingsNote(text: L("Needs Arduino IDE 2. The first time takes 1–2 minutes."), lines: 2)
                    .help(L("Compiles firmware/ESP32_Display from the project and uploads it to the board. Needs Arduino IDE 2 in Applications; the first time takes 1–2 minutes."))
            }
        }
    }

    func boardThumb(_ id: Int) -> some View {
        Button { store.showBoardPhoto(id) } label: {
            ZStack {
                Color.black
                if let image = store.boardThumbs[id] {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(Circle().stroke(id == store.currentPhoto ? Color.accentColor : Color.clear, lineWidth: 2.5))
        }
        .buttonStyle(.plain)
        .help(L("Show this photo"))
        .contextMenu {
            Button(L("Show on the board")) { store.showBoardPhoto(id) }
            Button(L("Delete from the board")) { store.deleteBoardPhoto(id) }
        }
    }

    func libraryThumb(_ item: LibraryItem) -> some View {
        Button { store.sendToBoard(item) } label: {
            ZStack {
                Color.black
                if let image = store.thumbs[item.id] {
                    Image(nsImage: image).resizable().scaledToFill()
                }
                if store.sending == item.id {
                    Color.black.opacity(0.5)
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.name)
        .contextMenu {
            Button(L("Show on the board")) { store.sendToBoard(item) }
            Button(L("Remove from the library")) { store.deleteFromLibrary(item) }
        }
    }
}

// MARK: - AI tab popovers: lists that need not show all the time

func nameLabel(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        Text(title).lineLimit(1)
        if !detail.isEmpty { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
    }.frame(maxWidth: .infinity, alignment: .leading)
}

struct CalendarList: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPopover(title: L("Calendars"), listHeight: CGFloat(store.calendars.count) * 36 + 20) {
            HStack(spacing: 0) {
                Spacer()
                Text(L("Read")).frame(width: 44)
                Text(L("Change")).frame(width: 44)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(store.calendars) { cal in
                HStack(spacing: 0) {
                    nameLabel(cal.title, cal.account)
                    Toggle(L("Read"), isOn: Binding(get: { cal.shown }, set: { store.setCalendarShown(cal.id, $0) }))
                        .labelsHidden().frame(width: 44)
                    Group {
                        if cal.canWrite {
                            Toggle(L("Change"), isOn: Binding(get: { cal.write }, set: { store.setCalendarWritable(cal.id, $0) }))
                                .labelsHidden()
                        } else {
                            Text("–").foregroundStyle(.tertiary)
                        }
                    }.frame(width: 44)
                }
                .toggleStyle(.checkbox)
                .frame(height: 36)
                if cal.id != store.calendars.last?.id { Divider() }
            }
        }
    }
}

struct MailAccountList: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPopover(title: L("Mail accounts"), listHeight: CGFloat(store.mailAccounts.count) * 32) {
            ForEach(store.mailAccounts) { acct in
                HStack(spacing: 0) {
                    nameLabel(acct.name, "")
                    Toggle(L("Read"), isOn: Binding(get: { acct.shown }, set: { store.setMailShown(acct.name, $0) }))
                        .labelsHidden().toggleStyle(.checkbox).frame(width: 44)
                }
                .frame(height: 32)
                if acct.id != store.mailAccounts.last?.id { Divider() }
            }
        }
    }
}

struct CalendarChanges: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPopover(title: L("Recent changes"), listHeight: CGFloat(store.calChanges.count) * 44) {
            ForEach(store.calChanges) { change in
                HStack(spacing: 8) {
                    Text(change.text).font(.system(size: 11)).lineLimit(2)
                        .foregroundStyle(change.undone ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(change.text)
                    if change.undone {
                        Text(L("Undone")).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        SettingsAction(title: L("Undo")) { store.undoCalendarChange(change.n) }.frame(width: 60)
                    }
                }
                .frame(height: 44)
                if change.id != store.calChanges.last?.id { Divider() }
            }
        }
    }
}

// MARK: - History: face changes by day, week, month or year

struct HistoryTab: View {
    @ObservedObject var store: SettingsStore

    static let kinds = [(L("Day"), "day"), (L("Week"), "week"), (L("Month"), "month"), (L("Year"), "year")]

    var chartTitle: String {
        switch store.historyKind {
        case "week": return L("Time of day")
        case "month": return L("Changes per day")
        case "year": return L("Changes per month")
        default: return L("Timeline")
        }
    }

    var body: some View {
        SettingsPage {
            SettingsSegments(options: HistoryTab.kinds,
                             selection: Binding(get: { store.historyKind }, set: { store.setHistoryKind($0) }))
            HStack(spacing: 6) {
                Button { store.moveDay(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(store.historyDayText).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Button { store.moveDay(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).disabled(store.isToday)
                Spacer()
                if !store.isToday {
                    SettingsAction(title: L("Today")) { store.goToday() }.fixedSize()
                }
                Text(String(format: L("%d changes"), store.dayTotal)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            SettingsCard(title: L("Who chose which faces")) { owners }
            SettingsCard(title: chartTitle) {
                Group {
                    switch store.historyKind {
                    case "week": WeekTimeline(rows: store.periodRows)
                    case "month": BarChart(rows: store.periodRows, labelEvery: 5)
                    case "year": BarChart(rows: store.periodRows)
                    default: TimelineStrip(events: store.timeline, day: store.periodBounds.0)
                    }
                }
                .padding(10)
            }
            SettingsCard(title: L("Saved history")) {
                SettingsRow(title: L("Delete")) {
                    SettingsAction(title: L("Delete all history…")) { store.clearHistory() }
                }
                SettingsNote(text: L("Each face change is saved on this Mac: only the time, who chose it and the mood. No conversation text is saved."), lines: 3)
            }
        }
    }

    /// One row per AI (and you): how many changes, their mix of emotion groups and top moods.
    var owners: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.dayTotal == 0 {
                Text(L("Nothing recorded in this period.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(OWNERS.filter { (store.dayStats[$0]?.count ?? 0) > 0 }, id: \.self) { owner in
                    let s = store.dayStats[owner] ?? OwnerStats()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(OWNER_COLOR[owner] ?? .gray).frame(width: 7, height: 7)
                            Text(OWNER_LABEL[owner] ?? owner).frame(width: 46, alignment: .leading)
                            Text("\(s.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                            GroupBar(groups: s.groups, total: s.count)
                        }
                        Text(s.top.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).padding(.leading, 13)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    Divider()
                }
                Legend(shown: Set(store.dayStats.values.flatMap { $0.groups.keys }))
                    .padding(10)
            }
        }
    }
}
