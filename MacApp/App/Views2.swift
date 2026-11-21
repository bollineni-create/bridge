import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApplicationServices

// MARK: Feeds
struct FeedRow: View {
    @EnvironmentObject var store: Store
    var source: String
    var item: FeedItem
    @State private var open = false

    var time: String {
        guard let t = item.ts, t > 1_000_000_000 else { return "" }
        if source == "calendar" { return (item.allday ?? false) ? clock(t, "EEE MMM d") + " · all day" : clock(t, "EEE MMM d · h:mm a") }
        let day = Calendar.current.isDateInToday(Date(timeIntervalSince1970: t))
        return clock(t, day ? "h:mm a" : "MMM d · h:mm a")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                if source == "reminders" {
                    Button { store.cli(["do", "reminder-complete", item.id, "--wait", "10"]) } label: { Image(systemName: "circle").font(SW.a(18, 700, width: 112)) }.buttonStyle(.plain).foregroundStyle(Ink.dim)
                } else if (item.unread ?? 0) > 0 || (item.flag ?? false) {
                    Circle().fill(source == "system" ? Ink.good : Ink.ultra).frame(width: 7, height: 7).padding(.top, 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source == "mail" ? (item.sub ?? "") : item.title).font(.system(size: 13.5, weight: (item.unread ?? 0) > 0 ? .bold : .medium)).lineLimit(2)
                        if (item.unread ?? 0) > 0 && source == "messages" { Pill(text: "\(item.unread!) unread", color: Ink.ultra) }
                    }
                    let second = source == "mail" ? item.title : (item.sub ?? "")
                    if !second.isEmpty { Text(second).font(SW.a(13.5, 400)).foregroundStyle(Ink.dim).lineLimit(open ? 12 : 2).textSelection(.enabled) }
                    if let d = item.detail, !d.isEmpty, source != "browser" { Text(d).font(SW.a(13, 400)).foregroundStyle(Ink.faint).lineLimit(open ? 10 : 1) }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if !time.isEmpty { Text(time).font(.subheadline.monospacedDigit()).foregroundStyle(Ink.dim) }
                    if let tag = item.tag, !tag.isEmpty { Pill(text: tag) }
                }
                if source == "shortcuts" { Button("Run") { store.cli(["shortcut", "run", item.title]) }.buttonStyle(QuietButton(color: Ink.mac)) }
                if source == "browser", let u = item.detail, let url = URL(string: u) { Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(QuietButton()) }
            }
            if open, let lines = item.lines {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(lines, id: \.self) { l in
                        HStack(alignment: .top) {
                            if l.me { Spacer(minLength: 60) }
                            VStack(alignment: l.me ? .trailing : .leading, spacing: 1) {
                                Text(l.text).font(SW.a(13.5, 400)).padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(l.me ? Ink.pro.opacity(0.35) : Color.primary.opacity(0.08), in: Rectangle()).textSelection(.enabled)
                                Text((l.me ? "" : l.who + " · ") + clock(l.ts, "MMM d · h:mm a")).font(SW.a(11.5, 400)).foregroundStyle(Ink.faint)
                            }
                            if !l.me { Spacer(minLength: 60) }
                        }
                    }
                }
                .padding(.leading, 6)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
    }
}

struct MusicControls: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Card(pad: 12) {
            HStack(spacing: 8) {
                Button { store.cli(["music", "prev"], quiet: true) } label: { Image(systemName: "backward.fill") }.buttonStyle(QuietButton())
                Button { store.cli(["music", "toggle"], quiet: true) } label: { Image(systemName: "playpause.fill") }.buttonStyle(QuietButton(color: Ink.mac))
                Button { store.cli(["music", "next"], quiet: true) } label: { Image(systemName: "forward.fill") }.buttonStyle(QuietButton())
                Text("Runners use the same controls: bridge music play | pause | next | playlist \"name\"").font(SW.a(13, 400)).foregroundStyle(Ink.faint)
                Spacer()
            }
        }
    }
}

struct FeedView: View {
    @EnvironmentObject var store: Store
    var source: String
    var title: String
    @State private var query = ""

    var feed: Feed? { store.snap?.feeds[source] }
    var items: [FeedItem] {
        let all = feed?.items ?? []
        let q = query.lowercased()
        if q.isEmpty { return all }
        return all.filter { ($0.title + " " + ($0.sub ?? "") + " " + ($0.tag ?? "")).lowercased().contains(q) }
    }
    var subtitle: String {
        switch source {
        case "calendar": return "Next 45 days from Apple Calendar, read through EventKit. Runners add events with: bridge do event-add"
        case "reminders": return "Open reminders from every list except ARCHIVE. Tick one to complete it."
        case "messages": return "Latest conversations, read straight from the Messages database. Click one to see the thread. Sending waits for your approval."
        case "mail": return "Newest mail across your accounts in the Mail app (junk, sent and trash left out)."
        case "notes": return "Most recently edited notes."
        case "contacts": return "Everyone with a number or email. Runners look people up with: bridge contact \"name\""
        case "browser": return "Open Safari tabs, then recent history from Safari and Chrome."
        case "music": return "What is playing in Music."
        case "location": return "Where this Mac is, from Location Services."
        case "system": return "The Activity Monitor numbers, sampled every few seconds, plus whether a VPN tunnel is up."
        default: return ""
        }
    }

    var body: some View {
        Page(title: title, subtitle: subtitle, trailing: AnyView(Freshness(feed: feed))) {
            if source == "music" { MusicControls() }
            if (feed?.count ?? 0) > 8 {
                TextField("Filter \(title.lowercased())", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            Card(pad: 12) {
                if items.isEmpty {
                    Text(feed?.fresh == true ? "Nothing to show." : ((feed?.detail ?? "").isEmpty ? "No data yet." : feed!.detail!)).font(SW.a(13.5, 400)).foregroundStyle(Ink.faint)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { it in
                            FeedRow(source: source, item: it)
                            if it.id != items.last?.id { Divider().overlay(Ink.line) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Apps
struct AppsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let apps = store.snap?.apps ?? []
        Page(title: "Apps", subtitle: "Every app Bridge tracks on this Mac, with live state. Runners use: bridge apps · bridge app open|quit \"name\"") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(apps) { a in
                    Card(pad: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                LiveDot(color: a.running ? Ink.good : Ink.faint, pulse: a.running && a.cpu > 15)
                                Text(a.name).font(SW.a(14, 700)).lineLimit(1)
                                Spacer()
                                if !a.version.isEmpty { Text(a.version).font(.caption.monospacedDigit()).foregroundStyle(Ink.faint) }
                            }
                            Text(!a.installed ? "Not installed" : (a.running ? String(format: "Running · %.0f%% CPU · %d MB", a.cpu, a.mem) : "Not running"))
                                .font(SW.a(13.5, 500)).foregroundStyle(a.running ? Color.primary : Ink.dim)
                            Text(a.note).font(SW.a(13, 400)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if a.installed {
                                HStack {
                                    Button(a.running ? "Bring forward" : "Open") { store.cli(["app", "open", a.id], quiet: true) }.buttonStyle(QuietButton(color: Ink.mac))
                                    if a.running { Button("Quit") { store.cli(["app", "quit", a.id], quiet: true) }.buttonStyle(QuietButton(color: Ink.bad)) }
                                }
                            }
                        }
                        .frame(minHeight: 112, alignment: .topLeading)
                    }
                }
            }
        }
    }
}

// MARK: Vault
struct VaultView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var hover = false
    @State private var confirm: VaultItem?

    var items: [VaultItem] {
        let all = store.snap?.vault?.items ?? []
        let q = query.lowercased()
        if q.isEmpty { return all }
        return all.filter { ($0.title + " " + ($0.host ?? "") + " " + ($0.username ?? "")).lowercased().contains(q) }
    }

    func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType.commaSeparatedText, UTType.plainText]
        p.allowsMultipleSelection = false
        p.message = "Choose the CSV exported from Passwords (File > Export All Passwords), Chrome or another manager"
        if p.runModal() == .OK, let u = p.url { store.importVault(u) }
    }

    var body: some View {
        Page(title: "Vault", subtitle: "\(store.snap?.vault?.count ?? 0) logins. Passwords are stored in your Mac's Keychain and only this app can read them.") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.largeTitle).foregroundStyle(hover ? Ink.mac : Ink.dim)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Drop a passwords CSV here").font(SW.a(18, 700, width: 112))
                            Text("Passwords app: File > Export All Passwords. Chrome and other managers work too. After the import Bridge offers to delete the CSV, because that file is the dangerous part.")
                                .font(SW.a(13.5, 400)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Choose CSV…", action: choose).buttonStyle(QuietButton(color: Ink.mac)).disabled(store.vaultBusy != nil)
                    }
                    if let busy = store.vaultBusy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(SW.a(13.5, 500)).monospacedDigit() }
                    } else if !store.vaultLast.isEmpty {
                        Label(store.vaultLast, systemImage: "checkmark.circle.fill").font(SW.a(13.5, 400)).foregroundStyle(.green)
                    }
                    Divider().overlay(Ink.line)
                    Toggle(isOn: Binding(get: { store.setting("vault_auto") }, set: { store.set("vault_auto", $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Let runners fill logins without asking me").font(SW.a(14, 500))
                            Text("Off: each fill waits in Needs You for your OK. Either way a runner only ever gets “filled”; the password never reaches a model, a log or iCloud.")
                                .font(SW.a(13, 400)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
                        }
                    }.toggleStyle(.switch)
                }
            }
            .overlay(Rectangle().stroke(hover ? Ink.mac : Color.clear, style: StrokeStyle(lineWidth: 2, dash: [6])))
            .onDrop(of: [UTType.fileURL], isTargeted: $hover) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { store.importVault(url) } }
                }
                return true
            }
            if (store.snap?.vault?.count ?? 0) > 6 { TextField("Search logins", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320) }
            Card(pad: 12) {
                if items.isEmpty { Text("No logins yet.").font(SW.a(13.5, 400)).foregroundStyle(Ink.faint) }
                else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { it in
                            HStack(spacing: 10) {
                                Image(systemName: "key.fill").foregroundStyle(Ink.warn).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(it.title).font(SW.a(14, 500)).lineLimit(1)
                                    Text([it.username ?? "", it.host ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(SW.a(13, 400)).foregroundStyle(Ink.dim).lineLimit(1)
                                }
                                Spacer()
                                if (it.hasOtp ?? 0) == 1 { Button("Code") { store.copySecret(it, "code") }.buttonStyle(QuietButton(color: Ink.pro)) }
                                Button("Copy password") { store.copySecret(it, "password") }.buttonStyle(QuietButton(color: Ink.mac))
                                Button { confirm = it } label: { Image(systemName: "trash") }.buttonStyle(QuietButton(color: Ink.bad))
                            }
                            .padding(.vertical, 6)
                            if it.id != items.last?.id { Divider().overlay(Ink.line) }
                        }
                    }
                }
            }
        }
        .alert("Remove this login from the vault?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Remove", role: .destructive) { if let c = confirm { store.deleteVault(c) }; confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: { Text(confirm?.title ?? "") }
    }
}

// MARK: Alarms & Shortcuts
struct ShortcutsView: View {
    @EnvironmentObject var store: Store
    @State private var when = Date().addingTimeInterval(3600)
    @State private var label = ""
    @State private var rep = ""

    func add() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var args = ["alarm", "add", f.string(from: when), label.isEmpty ? "Alarm" : label]
        if !rep.isEmpty { args += ["--repeat", rep] }
        label = ""
        store.cli(args)
    }

    var body: some View {
        let alarms = store.snap?.alarms ?? []
        Page(title: "Alarms & Shortcuts", subtitle: "Bridge alarms ring on this Mac and land in Needs You. Home scenes and anything else you built in Shortcuts run from here or from any runner.") {
            Heading(text: "Alarms")
            Card(pad: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        DatePicker("", selection: $when).labelsHidden()
                        TextField("Label", text: $label).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        Picker("", selection: $rep) { Text("Once").tag(""); Text("Daily").tag("daily"); Text("Weekdays").tag("weekdays") }.labelsHidden().frame(width: 110)
                        Button("Set alarm", action: add).buttonStyle(QuietButton(color: Ink.mac))
                        Spacer()
                    }
                    if alarms.isEmpty { Text("No alarms.").font(SW.a(13.5, 400)).foregroundStyle(Ink.faint) }
                    ForEach(alarms) { a in
                        HStack {
                            Image(systemName: a.enabled ? "alarm.fill" : "alarm").foregroundStyle(a.enabled ? Ink.warn : Ink.faint)
                            Text(a.time).font(.body.weight(.semibold).monospacedDigit())
                            Text(a.label).font(SW.a(14, 400))
                            Pill(text: a.source + ((a.repeat ?? "").isEmpty ? "" : " · " + a.repeat!))
                            Spacer()
                            if a.source == "Bridge" && a.enabled { Button("Turn off") { store.cli(["alarm", "off", a.id], quiet: true) }.buttonStyle(QuietButton()) }
                        }
                    }
                    Text("Alarms from the Clock app are shown read-only; macOS does not let other apps change them.").font(SW.a(13, 400)).foregroundStyle(Ink.faint)
                }
            }
            Heading(text: "Shortcuts", note: "Home scenes and alarms first")
            FeedBody(source: "shortcuts")
        }
    }
}

struct FeedBody: View {
    @EnvironmentObject var store: Store
    var source: String
    var body: some View {
        let items = store.snap?.feeds[source]?.items ?? []
        Card(pad: 12) {
            if items.isEmpty { Text("Nothing to show.").font(SW.a(13.5, 400)).foregroundStyle(Ink.faint) }
            else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { it in
                        FeedRow(source: source, item: it)
                        if it.id != items.last?.id { Divider().overlay(Ink.line) }
                    }
                }
            }
        }
    }
}

// MARK: Activity, Health, Settings
struct ActivityView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let evs = store.snap?.events ?? []
        Page(title: "Activity", subtitle: "Everything any runner, the engine or you did through Bridge, newest first.") {
            Card(pad: 12) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(evs) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Text(clock(e.ts, "h:mm:ss a")).font(.subheadline.monospacedDigit()).foregroundStyle(Ink.faint).frame(width: 84, alignment: .leading)
                            Text(Ink.who(e.actor)).font(SW.a(13, 700)).foregroundStyle(Ink.runner(e.actor)).frame(width: 62, alignment: .leading)
                            Text(e.type).font(SW.a(13, 500)).foregroundStyle(Ink.dim).frame(width: 92, alignment: .leading)
                            Text(e.text).font(SW.a(13.5, 400)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }
}

struct HealthView: View {
    @EnvironmentObject var store: Store
    func restart() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.naren.bridge.engine"]
            try? p.run()
        }
        store.say("Restarting the engine…")
    }
    var body: some View {
        let rows = store.snap?.health ?? []
        Page(title: "Health", subtitle: "The engine checks itself every minute and repairs what it can. Snapshot written \(ago(store.snap?.generated)).") {
            HStack {
                Button("Restart engine", action: restart).buttonStyle(QuietButton())
                Button("Run the 33 self-tests") { store.cli(["selftest"], quiet: true) { _, out in store.say(out.components(separatedBy: "\n").last ?? "") } }.buttonStyle(QuietButton(color: Ink.mac))
                Button(store.activityOn ? "Live Activity on" : "Start Live Activity") { store.updateActivity(force: true) }.buttonStyle(QuietButton(color: store.activityOn ? Ink.good : Ink.warn))
                Spacer()
            }
            Card(pad: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { h in
                        HStack(alignment: .top, spacing: 8) {
                            LiveDot(color: Ink.state(h.status))
                            Text(h.name).font(SW.a(14, 600)).frame(width: 190, alignment: .leading)
                            Text(h.detail).font(SW.a(13.5, 400)).foregroundStyle(h.status == "problem" ? Ink.bad : Ink.dim).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
    func perm(_ name: String, _ ok: Bool, _ place: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Ink.good : Ink.warn)
            Text(name).font(SW.a(14, 500))
            if !ok { Text("not granted · System Settings > \(place)").font(SW.a(13, 400)).foregroundStyle(Ink.warn) }
            Spacer()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    func row(_ key: String, _ title: String, _ note: String) -> some View {
        Toggle(isOn: Binding(get: { store.setting(key) }, set: { store.set(key, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SW.a(14, 500))
                Text(note).font(SW.a(13, 400)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true)
            }
        }.toggleStyle(.switch).padding(.vertical, 3)
    }
    var body: some View {
        Page(title: "Settings", subtitle: "Engine \(store.snap?.v ?? "") · model \(store.snap?.settings["model"] ?? "")") {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    row("local_auto", "Qwen works tasks sent to This Mac on its own", "Anything on the board marked for This Mac starts within a second, with no Claude usage.")
                    row("keep_loaded", "Keep Qwen loaded in memory", "Instant answers, at the cost of about 18 GB of RAM held all the time.")
                    row("msg_auto", "Send iMessages without asking me", "Off: every message a runner wants to send as you waits in Needs You.")
                    row("vault_auto", "Fill logins without asking me", "Off: every vault fill waits in Needs You.")
                    row("music_on", "Music lane", "Now playing and controls. macOS asks once whether Bridge may control Music.")
                    row("live_activity", "Live Activity in the menu bar", "Who is working and what is open, next to the clock.")
                    row("read_windows", "Read what Claude and Claude Pro are doing", "Shows the real chat title and step on each card. Live while Bridge is in front, every 5 minutes otherwise, because each read makes macOS show its own “Bridge is accessing…” pill beside the Live Activity for about a minute.")
                }
            }
            Card(pad: 12) {
                Text("Engine: ~/Claude/bridge/bridge.py (command: bridge)\nStore: ~/Library/Application Support/Bridge/bridge.db (local, never synced)\niCloud mirror for the account that cannot reach the Mac: iCloud Drive > AI > claude-bridge")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Ink.dim).textSelection(.enabled)
            }
        }
    }
}

// MARK: Menu bar
func dotsImage(_ states: [(String, String)], needs: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: 40, height: 16), flipped: false) { _ in
        for (i, s) in states.enumerated() {
            let base: NSColor = s.0 == "ultra" ? NSColor(red: 1, green: 0.48, blue: 0.27, alpha: 1) : (s.0 == "pro" ? NSColor(red: 0.55, green: 0.49, blue: 0.96, alpha: 1) : NSColor(red: 0.2, green: 0.83, blue: 0.6, alpha: 1))
            let on = ["working", "ready", "holding"].contains(s.1)
            let rect = NSRect(x: CGFloat(i) * 13 + 2, y: 3.5, width: 9, height: 9)
            if on { base.setFill(); NSBezierPath(ovalIn: rect).fill() }
            else { base.withAlphaComponent(0.7).setStroke(); let p = NSBezierPath(ovalIn: rect.insetBy(dx: 0.8, dy: 0.8)); p.lineWidth = 1.4; p.stroke() }
            if s.1 == "working" { NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill() }
        }
        return true
    }
    img.isTemplate = false
    return img
}

struct MenuLabel: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let states = (store.snap?.runners ?? []).map { ($0.id, $0.state) }
        let needs = store.snap?.counts.needs ?? 0
        HStack(spacing: 3) {
            Image(nsImage: dotsImage(states.isEmpty ? [("ultra", "x"), ("pro", "x"), ("local", "x")] : states, needs: needs))
            if needs > 0 { Text("\(needs)") }
        }
        .onAppear {
            WindowOpener.store = store
            WindowOpener.open = { openWindow(id: "main") }
            WindowOpener.openCompact = { openWindow(id: "compact"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

struct MenuPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { BridgeMark(size: 22); Text("Bridge").font(SW.a(14, 700)); Spacer(); Text(store.engineLive ? "live" : "engine offline").font(SW.a(13, 400)).foregroundStyle(store.engineLive ? Ink.good : Ink.bad) }
            ForEach(store.snap?.runners ?? []) { r in
                HStack(spacing: 6) {
                    LiveDot(color: Ink.state(r.state), pulse: r.state == "working")
                    Text(r.name).font(SW.a(13.5, 700)).foregroundStyle(Ink.runner(r.id)).frame(width: 62, alignment: .leading)
                    Text(r.text).font(SW.a(13.5, 400)).lineLimit(1)
                    Spacer()
                }
            }
            if let c = store.snap?.counts {
                Text("\(c.open) open · \(c.working) in motion · \(c.needs + c.naren) waiting on you").font(SW.a(13, 400)).foregroundStyle(Ink.dim)
            }
            HStack {
                TextField("Ask or hand off…", text: $text).textFieldStyle(.roundedBorder).onSubmit {
                    let q = text.trimmingCharacters(in: .whitespaces)
                    if !q.isEmpty { store.cli(["ask", q], quiet: true); text = "" }
                }
            }
            HStack {
                Button("Open Bridge") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.buttonStyle(QuietButton(color: Ink.mac))
                Button("Compact") { openWindow(id: "compact"); NSApp.activate(ignoringOtherApps: true) }.buttonStyle(QuietButton())
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(QuietButton())
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}


/// The feeds are not screens to browse. They are context: what both Claude accounts and Qwen can read, through the Bridge connector.
struct ContextView: View {
    @EnvironmentObject var store: Store
    static let sources: [(String, String, String)] = [
        ("calendar", "Calendar", "calendar"), ("reminders", "Reminders", "checklist"), ("messages", "Messages", "message.fill"), ("mail", "Mail", "envelope.fill"),
        ("notes", "Notes", "note.text"), ("contacts", "Contacts", "person.2.fill"), ("browser", "Safari and Chrome", "safari.fill"),
        ("location", "Location", "location.fill"), ("music", "Music", "music.note"), ("system", "This Mac's activity", "cpu"), ("shortcuts", "Shortcuts and Home scenes", "house.fill")]
    func connected(_ path: String) -> Bool {
        ((try? String(contentsOfFile: NSHomeDirectory() + path, encoding: .utf8)) ?? "").contains("bridge_mcp.py")
    }
    func row(_ name: String, _ ok: Bool, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Ink.good : Ink.warn)
            Text(name).font(SW.a(14, 500))
            Spacer()
            Text(detail).font(SW.a(13.5, 400)).foregroundStyle(.secondary)
        }
    }
    var body: some View {
        Page(title: "Context", subtitle: "Everything here is handed to your Claude accounts and Qwen automatically. There is nothing to open or paste.") {
            Heading(text: "Connected to")
            Card(pad: 12) {
                VStack(spacing: 8) {
                    row("Claude · Ultra", connected("/Library/Application Support/Claude/claude_desktop_config.json"), "Bridge connector")
                    Divider()
                    row("Claude Pro", connected("/Library/Application Support/Duplex/claude-2/data/claude_desktop_config.json"), "Bridge connector")
                    Divider()
                    row("This Mac · Qwen", store.engineLive, "reads the engine directly")
                }
            }
            Heading(text: "What they can read", note: "live from this Mac")
            Card(pad: 12) {
                VStack(spacing: 8) {
                    ForEach(Array(Self.sources.enumerated()), id: \.offset) { i, s in
                        if i > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: s.2).frame(width: 22).foregroundStyle(.secondary)
                            Text(s.1).font(SW.a(14, 500))
                            Text("\(store.snap?.feeds[s.0]?.items.count ?? 0)").font(SW.a(13.5, 400)).monospacedDigit().foregroundStyle(.secondary)
                            Spacer()
                            Freshness(feed: store.snap?.feeds[s.0])
                        }
                    }
                }
            }
            Heading(text: "What Bridge is allowed to do on this Mac")
            PermissionsCard(perms: store.perms)
        }
    }
}
