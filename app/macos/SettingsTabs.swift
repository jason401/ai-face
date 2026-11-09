// The four settings tabs (General · Appearance · AI · History) and the board details window, built from the cards in SettingsKit.swift.
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General: shared App → Updates → Folders → About layout

struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("App")) {
                SettingsRow(title: L("Open at login")) {
                    SettingsSwitch(title: L("Open at login"), isOn: Binding(get: { store.loginItem }, set: { store.setLogin($0) }))
                        .help(L("The face appears in the menu bar as soon as you log in."))
                }
            }
            SettingsCard(title: L("Updates")) {
                SettingsRow(title: L("Check automatically")) {
                    SettingsSwitch(title: L("Check for updates automatically"), isOn: Binding(get: { store.autoUpdate }, set: { store.setAutoUpdate($0) }))
                        .help(L("Check for updates automatically"))
                }
                Divider()
                SettingsRow(title: L("Channel")) {
                    SettingsMenu(options: [(L("Stable"), "stable"), (L("Beta (main, for testing)"), "main")],
                                 selection: Binding(get: { store.updateChannel }, set: { store.setUpdateChannel($0) }))
                        .disabled(store.updateRunning)
                        .help(L("Stable gets versions that were published after testing. Beta follows main, where new changes arrive first; it may be broken. Going back to Stable updates once stable catches up with the version you run."))
                }
                Divider()
                if let progress = store.updateProgress {
                    UpdateProgressBar(progress: progress)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                if store.updateProgress == nil || !store.updateRunning {
                    SettingsRow(title: L("New version")) {
                        if store.updateAvailable {
                            Button(action: { store.installUpdate() }) {
                                Text(L("Update Now")).lineLimit(1).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 24)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                            }.buttonStyle(.plain).disabled(store.updateRunning)
                        } else {
                            SettingsAction(title: L("Check Now")) { store.checkUpdate() }
                                .disabled(store.updateRunning)
                        }
                    }
                }
                SettingsNote(text: (store.updateChannel == "main" ? L("Beta: changes may not be tested yet.") + "\n" : "")
                             + store.updateText, lines: 5)
                    .textSelection(.enabled)
                    .help(L("AI Face looks for a new version of the chosen channel on GitHub at startup and every 3 hours, but installs it only when you click Update now (here or in the menu). It then tests and builds it in its own source folder and restarts. Your development folder is never changed. Existing Python and Command Line Tools are required."))
            }
            SettingsCard(title: L("Folders")) {
                SettingsRow(title: L("Open")) {
                    SettingsAction(title: L("App data")) { store.openDataFolder() }
                        .help(L("Settings, photos, history, the update copy and backups"))
                    SettingsAction(title: L("App")) { store.revealApp() }
                        .help(Bundle.main.bundlePath)
                }
            }
            SettingsCard(title: L("About")) {
                SettingsRow(title: L("Version")) {
                    Text(store.version).foregroundStyle(.secondary).textSelection(.enabled)
                        .help(store.versionDetail)
                }
                Divider()
                SettingsRow(title: L("Licenses")) {
                    SettingsAction(title: L("Show")) {
                        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .disabled(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") == nil)
                }
            }
        }
        .environment(\.settingsLabelWidth, 118)
    }
}

private struct UpdateProgressBar: View {
    let progress: UpdateProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(0 ..< UpdateProgress.stages.count, id: \.self) { step in
                        VStack(alignment: .leading, spacing: 3) {
                            segment(step, now)
                            Text(UpdateProgress.names[step] + (step < progress.stage ? " ✓" : ""))
                                .font(.system(size: 10, weight: step == progress.stage ? .semibold : .regular))
                                .foregroundStyle(step == progress.stage ? Color.primary : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Text(progress.summary(at: now))
                    .font(.system(size: 11)).foregroundStyle(tint == .accentColor ? Color.primary : tint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let output = output(now) {
                    Text(output).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)   // a long line must not squeeze the steps
                        .help(progress.line)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color { progress.failed ? .red : progress.waiting ? .yellow : .accentColor }

    private func segment(_ step: Int, _ now: Date) -> some View {
        let current = step == progress.stage
        let fill: Double = step < progress.stage ? 1
            : current ? (progress.failed || progress.waiting ? 1 : progress.fraction(at: now) ?? 0.5) : 0
        // Without last time's duration the current segment pulses instead of pretending to know.
        let pulse = current && !progress.failed && !progress.waiting && progress.fraction(at: now) == nil
            && Int(now.timeIntervalSince1970) % 2 == 1
        return GeometryReader { box in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(current ? tint : Color.accentColor)
                    .frame(width: box.size.width * fill)
                    .opacity(pulse ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.9), value: pulse)
            }
        }
        .frame(height: 4)
    }

    private func output(_ now: Date) -> String? {
        let quiet = progress.quiet(at: now).map { String(format: L("no output for %@"), UpdateProgress.duration($0)) }
        guard !progress.line.isEmpty || quiet != nil else { return nil }
        return "› " + [progress.line, quiet].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Appearance: the face, the campfire weather and the board (details in their own window)

struct AppearanceTab: View {
    @ObservedObject var store: SettingsStore

    func bind<T>(_ path: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        return Binding(get: { store[keyPath: path] }, set: { store[keyPath: path] = $0; store.saveSaver() })
    }

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("Face")) {
                SettingsRow(title: L("Colors")) {
                    Toggle(L("Monochrome"), isOn: Binding(get: { store.mono }, set: { store.setMono($0) }))
                        .toggleStyle(.checkbox)
                        .help(L("Draws the menu bar face in grays and shows who chose it by the ring pattern: you = solid, Claude = short dashes, GPT = six long arcs, AI Illuminati = dots. The board always stays in color."))
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
                Divider()
                SettingsRow(title: L("Clock design")) {
                    SettingsMenu(options: CLOCK_DESIGNS.enumerated().map { ($0.element, $0.offset) },
                                 selection: Binding(get: { store.clockStyle }, set: { store.setClockStyle($0) }))
                        .help(L("How the clock looks on the board (clock screen and clock screen saver). The menu bar keeps the simple clock."))
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
            CampfireWeatherCard(store: store)
            BoardCard(store: store)
        }
    }
}

extension SettingsStore {
    var boardStatus: String {
        connected ? L("Connected") : (ports.isEmpty ? L("Not connected") : L("Connecting or error"))
    }

    func lightBinding<T>(_ path: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(get: { self[keyPath: path] }, set: { self[keyPath: path] = $0; self.saveLight() })
    }
}

/// The board in short: whether it is there, how bright, and a button for everything else.
/// The board is often unplugged, so its controls wait (dimmed) until it connects.
struct BoardCard: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsCard(title: L("Board")) {
            SettingsRow(title: L("Status")) {
                SettingsStatus(text: store.boardStatus, ok: store.connected)
                if !store.connected && !store.ports.isEmpty {
                    SettingsAction(title: L("Reconnect")) { store.reconnect() }.fixedSize()
                }
            }
            Divider()
            SettingsRow(title: L("Brightness")) {
                SettingsMenu(options: stride(from: 10, through: 100, by: 10).map { ("\($0)%", $0) },
                             selection: store.lightBinding(\.lightBright))
                    .disabled(!store.connected)
            }
            Divider()
            SettingsRow(title: L("More")) {
                SettingsAction(title: L("Details…")) { store.openBoard?() }
                    .help(L("Screen light, photos on the board, the photo library and firmware"))
            }
            SettingsNote(text: store.connected ? L("Screen light, photos and firmware are in Details.")
                         : (store.message.isEmpty ? L("Plug in the board to change its settings.") : store.message), lines: 2)
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

    /// One checkbox per AI for a read or write switch (AI Illuminati only when it is installed).
    func perAI(_ claude: Bool, _ gpt: Bool, _ illuminati: Bool, _ set: @escaping (String, Bool) -> Void) -> some View {
        HStack(spacing: store.illuminatiAvailable ? 3 : 14) {
            Toggle("Claude", isOn: Binding(get: { claude }, set: { set("claude", $0) })).fixedSize()
            Toggle("GPT", isOn: Binding(get: { gpt }, set: { set("gpt", $0) })).fixedSize()
            if store.illuminatiAvailable {
                Toggle("Illuminati", isOn: Binding(get: { illuminati }, set: { set("illuminati", $0) })).fixedSize()
                    .help("AI Illuminati")
            }
        }.toggleStyle(.checkbox).font(.system(size: store.illuminatiAvailable ? 11 : 12))
    }

    func accessRow(_ text: String, ok: Bool, busy: Bool = false, button: String?, title: String = L("Access"),
                   _ action: @escaping () -> Void) -> some View {
        SettingsRow(title: title) {
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
                if store.illuminatiAvailable {
                    Divider()
                    appRow("AI Illuminati", store.illuminati, "illuminati")
                        .help(L("AI Illuminati shows its plain-chat replies here as its own AI (gold ring), whichever model answers. No restart needed: it applies within 30 seconds."))
                }
                SettingsNote(text: store.aiNotice.isEmpty ? L("After connecting or disconnecting, quit that app (⌘Q) and open it again.") : store.aiNotice, lines: 3)
                    .help(L("Once connected, the AI picks a face for every reply. After connecting or disconnecting, quit that app (⌘Q) and open it again. Ring colors: Claude orange, GPT green, AI Illuminati gold, your own picks white."))
            }

            if store.awakeSupported {
                SettingsCard(title: L("Keep awake")) {
                    accessRow(store.awakeReady ? L("Allowed") : L("Not set up"), ok: store.awakeReady,
                              button: store.awakeReady ? L("Remove…") : L("Set up…"), title: L("Permission")) {
                        store.setUpAwake(remove: store.awakeReady)
                    }
                    .help(store.awakeReady ? L("Removes the permission and the awake command (in Terminal, with your Mac password).")
                          : L("Asks for your Mac password once, in Terminal, and allows only this one setting."))
                    Divider()
                    SettingsRow(title: L("Status")) {
                        SettingsStatus(text: store.awakeStatus, ok: store.awakeOn)
                    }
                    Group {
                        Divider()
                        SettingsRow(title: "Claude Code") {
                            Toggle(L("While it works"), isOn: Binding(get: { store.hooks == "on" },
                                                                      set: { store.setAI("claude_code_awake", on: $0) }))
                                .toggleStyle(.checkbox)
                                .help(L("Claude Code: keep the Mac awake while it works"))
                        }
                        Divider()
                        SettingsRow(title: L("AI can ask")) {
                            perAI(store.awakeClaude, store.awakeGPT, store.awakeIlluminati) { ai, on in store.setAwakeApps(ai, on) }
                                .help(L("Which AIs may keep the Mac awake when you ask them to (up to 4 hours, renewed while they work)."))
                        }
                        Divider()
                        SettingsRow(title: L("Terminal command")) {
                            if store.awakeCommand {
                                SettingsStatus(text: L("Installed"))
                            } else {
                                SettingsAction(title: L("Install…")) { store.setUpAwake() }
                            }
                        }
                        .help(L("In Terminal, awake COMMAND keeps the Mac awake while COMMAND runs (for example: awake python train.py)."))
                    }
                    .disabled(!store.awakeReady)
                    SettingsNote(text: store.awakeNotice.isEmpty
                                 ? L("Lid closed, 1–4 hours from the menu. Turns off by itself.") : store.awakeNotice, lines: 3)
                        .help(L("Keeps the MacBook awake even with the lid closed, for 1, 2 or 4 hours (menu → Keep awake). It turns off at the end, at 20% battery, when the Mac gets hot, in Low Power Mode and when AI Face quits. Setting it up asks for your Mac password once, in Terminal, and allows only this one setting."))
                }
            }

            SettingsCard(title: L("Shared folders")) {
                SettingsRow(title: L("Can read")) {
                    perAI(store.folderClaude, store.folderGPT, store.folderIlluminati) { ai, on in store.setFolderApps(ai, on) }
                }
                Divider()
                SettingsRow(title: L("Folder list")) {
                    SettingsAction(title: store.folders.isEmpty ? L("Add folders…")
                                   : String(format: L("%d of %d on…"), store.folders.filter { $0.on }.count, store.folders.count)) {
                        if store.folders.isEmpty { store.chooseFolders() } else { store.showFolders = true }
                    }
                    .popover(isPresented: $store.showFolders, arrowEdge: .bottom) { FolderList(store: store) }
                }
                Divider()
                SettingsRow(title: L("Quick panel")) {
                    Toggle(L("Show on hover over the face"), isOn: $store.folderShelfHover).toggleStyle(.checkbox)
                        .help(L("A panel under the menu bar face lists the shared folders. It also appears by itself while you drag a folder: drop it there to share it."))
                }
                SettingsNote(text: store.folderNotice.isEmpty ? L("Read only. Drop folders here. Hidden and secret files are never shown.") : store.folderNotice, lines: 2)
                    .help(L("Folders you share here can be listed, searched and read from Claude desktop, Claude Code and Codex on this Mac, by the AIs you allow. Nothing is changed or deleted. Hidden files, keys and .env files are never shown, and paths cannot leave the folder. File text sent to an AI becomes part of that conversation."))
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(store.folderDropping ? 1 : 0))
            .onDrop(of: [UTType.fileURL], isTargeted: $store.folderDropping) { providers in
                droppedURLs(providers) { store.addFolders($0) }
            }

            SettingsCard(title: L("Calendar")) {
                accessRow(store.calAccessText, ok: store.calAccess == "full", button: calendarButton) { store.requestCalendarAccess() }
                Divider()
                SettingsRow(title: L("Can read")) {
                    perAI(store.calClaude, store.calGPT, store.calIlluminati) { ai, on in store.setCalendar(["apps": [ai: on]]) }
                }
                Divider()
                SettingsRow(title: L("Can change")) {
                    perAI(store.calWriteClaude, store.calWriteGPT, store.calWriteIlluminati) { ai, on in store.setCalendar(["write_apps": [ai: on]]) }
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
                    perAI(store.mailClaude, store.mailGPT, store.mailIlluminati) { ai, on in store.setMail(["apps": [ai: on]]) }
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
        .onAppear { store.loadCalendar(); store.loadMail(); store.loadFolders() }
    }
}

// MARK: - Board details window: connection, screen light, photos, firmware

struct BoardDetails: View {
    // No @State: the Command Line Tools have no SwiftUI macro plugin, and the newest SDK
    // resolves @State to a macro. View state lives in the store instead.
    @ObservedObject var store: SettingsStore

    var hours: [(String, Int)] { (0..<24).map { (String(format: L("%d:00"), $0), $0) } }

    func lightBind<T>(_ path: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        store.lightBinding(path)
    }

    var body: some View {
        SettingsPage {
            SettingsCard(title: L("Connection")) {
                SettingsRow(title: L("Status")) {
                    SettingsStatus(text: store.boardStatus, ok: store.connected)
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
                    Divider()
                    SettingsRow(title: L("Touch")) {
                        SettingsStatus(text: store.touch > 0 ? L("Swipe left or right") : L("No touch panel"), ok: store.touch > 0)
                            .help(L("Swipe on the board to go face → campfire → clock → face (the other way swiping right)."))
                    }
                }
                if !store.message.isEmpty {
                    SettingsNote(text: store.message, lines: 3).textSelection(.enabled)
                }
            }

            SettingsCard(title: L("Screen light")) {
                SettingsRow(title: L("Brightness")) {
                    SettingsMenu(options: stride(from: 10, through: 100, by: 10).map { ("\($0)%", $0) },
                                 selection: lightBind(\.lightBright))
                }
                Divider()
                SettingsRow(title: L("Off when asleep")) {
                    SettingsSwitch(title: L("Off when asleep"), isOn: lightBind(\.lightOffSleeping))
                        .help(L("The screen goes dark while the sleeping face shows (screen saver)."))
                }
                Divider()
                SettingsRow(title: L("Off at night")) {
                    SettingsSwitch(title: L("Off at night"), isOn: lightBind(\.lightNight))
                }
                if store.lightNight {
                    Divider()
                    SettingsRow(title: L("Night")) {
                        SettingsMenu(options: hours, selection: lightBind(\.lightFrom))
                        Text("–").foregroundStyle(.secondary)
                        SettingsMenu(options: hours, selection: lightBind(\.lightTo))
                    }
                }
                SettingsNote(text: L("A touch lights a dark screen for 30 s; a timer alarm lights it too."), lines: 2)
                    .help(L("Needs the BLK wire on D0. The night hours use the board's clock, set by the Mac."))
            }
            .disabled(!store.connected)

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
                // Files from Finder, and pictures from the Photos app or a screenshot thumbnail.
                .onDrop(of: [UTType.fileURL, UTType.image, UTType.item], isTargeted: $store.dropping) { providers in
                    store.notice = L("Adding to the library…")
                    PictureDrop.receive(providers) { urls, folder in
                        store.addPictures(urls)   // reads the files right away
                        if let folder = folder { try? FileManager.default.removeItem(at: folder) }
                    }
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

/// The file URLs in a drop, on the main thread.
func droppedURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) -> Bool {
    var urls: [URL] = []
    let group = DispatchGroup()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url = url { DispatchQueue.main.async { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls) }
    return true
}

struct FolderList: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Shared folders")).font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(spacing: 0) {
                    if store.folders.isEmpty {
                        Text(L("No folders yet. Add one, or drop folders here."))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(store.folders) { folder in row(folder) }
                }
            }
            .frame(height: min(320, max(60, CGFloat(store.folders.count) * 41)))
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(store.folderDropping ? 1 : 0))
            .onDrop(of: [UTType.fileURL], isTargeted: $store.folderDropping) { providers in
                droppedURLs(providers) { store.addFolders($0) }
            }
            SettingsAction(title: L("Add folder…")) { store.chooseFolders() }
            if !store.folderNotice.isEmpty {
                Text(store.folderNotice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(12)
        .frame(width: 320)
    }

    func row(_ folder: SharedFolder) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if folder.missing {
                    Image(systemName: "questionmark.folder").foregroundStyle(.secondary).frame(width: 18)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 18, height: 18)
                }
                nameLabel(folder.name, folder.missing ? L("Not found: moved or deleted?")
                          : (folder.last.isEmpty ? folder.shortPath : folder.last))
                    .help(folder.path)
                    .opacity(folder.on || folder.missing ? 1 : 0.5)
                if folder.missing {
                    SettingsAction(title: L("Locate…")) { store.locateFolder(folder) }.frame(width: 64)
                } else {
                    Toggle(L("Share"), isOn: Binding(get: { folder.on }, set: { store.setFolderOn(folder, $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .help(L("Off: paused, the AIs cannot read it until you turn it on again"))
                }
                Button { store.removeFolder(folder) } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Stop sharing (the folder itself is not touched)"))
            }
            .frame(height: 40)
            if folder.id != store.folders.last?.id { Divider() }
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
                Text(String(format: L("%@ changes"), compactCount(store.dayTotal))).foregroundStyle(.secondary)
                    .lineLimit(1).layoutPriority(1).help(store.dayTotal.formatted())
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
                    SettingsAction(title: L("Delete this Mac’s history…")) { store.clearHistory() }
                }
                SettingsNote(text: L("Each face change is saved on this Mac: only the time, who chose it and the mood. No conversation text is saved."), lines: 3)
            }
            SettingsCard(title: L("iCloud Drive sync")) {
                SettingsRow(title: L("Sync history")) {
                    Toggle(L("Sync history"), isOn: Binding(
                        get: { store.historySyncOn }, set: { store.setHistorySync($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if store.historySyncOn {
                    SettingsRow(title: L("Status")) {
                        Text(store.historySyncText).font(.system(size: 11)).foregroundStyle(.secondary)
                        SettingsAction(title: L("Sync now")) { store.syncHistoryNow() }
                            .disabled(store.historySyncState == "syncing")
                    }
                    if store.historyDevices.count > 1 {
                        SettingsRow(title: L("Devices")) {
                            Picker(L("Devices"), selection: Binding(
                                get: { store.historyDevice }, set: { store.setHistoryDevice($0) })) {
                                Text(L("All devices")).tag("all")
                                Text(L("This Mac")).tag("local")
                                ForEach(Array(store.historyDevices.dropFirst().enumerated()), id: \.offset) { _, device in
                                    Text(device["name"] ?? "Mac").tag(device["id"] ?? "")
                                }
                            }.labelsHidden()
                        }
                    }
                }
                SettingsNote(text: L("When enabled, existing history is copied to iCloud Drive and history from your other Macs is shown together. Turning this off keeps all saved copies."), lines: 4)
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
                            Text(OWNER_LABEL[owner] ?? owner).frame(width: 58, alignment: .leading).lineLimit(1)
                            CountText(count: s.count)
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
