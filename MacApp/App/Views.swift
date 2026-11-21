import SwiftUI
import AppKit

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case chat, command, board, needs, calendar, reminders, messages, mail, notes, contacts, browser, music, location, apps, system, shortcuts, vault, activity, health, settings, context
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: return "Chat"
        case .command: return "Command"
        case .board: return "Board"
        case .needs: return "Needs You"
        case .shortcuts: return "Alarms & Shortcuts"
        default: return rawValue.capitalized
        }
    }
    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .command: return "sparkles"
        case .board: return "rectangle.3.group"
        case .needs: return "hand.raised"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .messages: return "message"
        case .mail: return "envelope"
        case .notes: return "note.text"
        case .contacts: return "person.2"
        case .browser: return "safari"
        case .music: return "music.note"
        case .location: return "location"
        case .apps: return "square.grid.2x2"
        case .system: return "cpu"
        case .shortcuts: return "alarm"
        case .vault: return "lock.shield"
        case .activity: return "waveform.path.ecg"
        case .health: return "stethoscope"
        case .settings: return "gearshape"
        case .context: return "square.stack.3d.up.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var pane: Pane = .chat      // Chat is the main way to drive the runners (Nov 21, 2026)
    var body: some View {
        // Design-system shell (ShellDS.swift): floating sidebar panel + detail on warm paper, filling the window at any size.
        HStack(spacing: 0) {
            SidebarDS(pane: $pane)
            DetailView(pane: pane, go: { pane = $0 }).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.bg)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            if !store.toast.isEmpty {
                Text(store.toast).font(SW.a(13.5, 500)).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Rectangle()).overlay(Rectangle().stroke(Ink.line)).padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .onOpenURL { u in AppDelegate.shared?.route(u) }
        .onChange(of: store.paneTick) { _, _ in if let p = Pane(rawValue: store.requestedPane) { pane = p } }
        .onAppear { if let p = Pane(rawValue: store.requestedPane) { pane = p } }
        .frame(minWidth: 980, minHeight: 640)
        // Follows macOS appearance live (Light, Dark or Auto): every DS / Ink colour is a light|dark pair. Nov 21, 2026.
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @Binding var pane: Pane?

    func badge(_ p: Pane) -> Int {
        guard let s = store.snap else { return 0 }
        switch p {
        case .needs: return s.counts.needs + s.counts.naren
        case .board: return s.counts.open + s.counts.working
        case .messages: return (s.feeds["messages"]?.items ?? []).reduce(0) { $0 + ($1.unread ?? 0) }
        case .mail: return (s.feeds["mail"]?.items ?? []).reduce(0) { $0 + ($1.unread ?? 0) }
        case .vault: return s.vault?.count ?? 0
        default: return 0
        }
    }

    func rows(_ ps: [Pane]) -> some View {
        ForEach(ps) { p in
            NavigationLink(value: p) { Label { Text(p.title) } icon: { SidebarIcon(symbol: p.icon, tint: p.tint) } }.badge(badge(p))
        }
    }

    var body: some View {
        List(selection: $pane) {
            Section {
                HStack(spacing: 10) {
                    // Design system: the three runner bars are the small mark; engine state lives in the StatusStrip.
                    HStack(alignment: .center, spacing: 3) {
                        Capsule().fill(DS.ultra).frame(width: 4, height: 9)
                        Capsule().fill(DS.pro).frame(width: 4, height: 14)
                        Capsule().fill(DS.mac).frame(width: 4, height: 20)
                    }
                    .frame(height: 20)
                    Text("Bridge").font(SW.a(20, 700))
                }
                .padding(.vertical, 6)
            }
            Section("Bridge") { rows([.chat, .command, .board, .needs]) }
            Section("What Claude can use") { rows([.context, .apps, .shortcuts, .vault]) }
            Section("Engine") { rows([.activity, .health, .settings]) }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 260)
    }
}

struct DetailView: View {
    @EnvironmentObject var store: Store
    var pane: Pane
    var go: (Pane) -> Void = { _ in }
    var body: some View {
        if store.snap == nil {
            Page(title: "Bridge", subtitle: "Waiting for the engine") {
                Card { Text(store.decodeError.isEmpty ? "The engine has not written a snapshot yet. It starts on its own; if this stays, open Health." : "Could not read the snapshot: \(store.decodeError)").foregroundStyle(Ink.dim) }
            }
        } else {
            VStack(spacing: 0) {
            StatusStrip()
            switch pane {
            case .chat: ChatDSView()
            case .command: KitPane(which: "command", open: { go($0 == "needs" ? .needs : .board) })   // BridgeKit (KitPanes.swift); CommandDSView stays for reference   // design-system Command pane (CommandDS.swift); the old CommandView stays for reference
            case .board: KitPane(which: "board")
            case .needs: KitPane(which: "needs")
            case .apps: AppsView()
            case .vault: VaultView()
            case .shortcuts: ShortcutsView()
            case .activity: ActivityView()
            case .health: HealthView()
            case .settings: SettingsView()
            case .context: ContextView()
            default: FeedView(source: pane.rawValue, title: pane.title)
            }
            }
        }
    }
}

// MARK: Command
struct AskBar: View {
    @EnvironmentObject var store: Store
    @State private var text = ""
    @State private var who = "auto"
    @State private var place = "auto"
    @State private var project = "Mission"
    let projects = ["Mission", "Med School", "Personal", "Hobbies + Sports", "Family", "Portfolio Optimization", "Exploring", "Transcripts"]

    func send() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var args = ["ask", q, "--who", who, "--where", place]
        if place == "project" { args += ["--project", project] }
        text = ""
        store.cli(args, quiet: true) { ok, out in
            guard ok, let d = out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { store.say(out); return }
            store.say("T\(j["tid"] ?? "?") → \(Ink.who(j["who"] as? String)) · \(j["dest"] as? String ?? "")")
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Ask anything, or hand off a job. Bridge sends it to the right runner.", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(SW.a(18, 700, width: 112)).lineLimit(1...6).onSubmit(send)
                HStack(spacing: 8) {
                    Picker("", selection: $who) {
                        Text("Auto route").tag("auto"); Text("Ultra").tag("ultra"); Text("Pro").tag("pro"); Text("This Mac (Qwen)").tag("local")
                    }.labelsHidden().frame(width: 150)
                    Picker("", selection: $place) {
                        Text("Auto place").tag("auto"); Text("Open chat").tag("open"); Text("New chat").tag("new"); Text("Project").tag("project")
                    }.labelsHidden().frame(width: 120)
                    if place == "project" {
                        Picker("", selection: $project) { ForEach(projects, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 170)
                    }
                    Spacer()
                    Button("Send", action: send).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }
}

struct RunnerCard: View {
    @EnvironmentObject var store: Store
    var r: Runner
    var holding: [BTask] { (store.snap?.tasks ?? []).filter { $0.live && $0.holder == r.id } }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(Ink.runner(r.id)).frame(width: 10, height: 10)
                    Text(r.name).font(SW.a(18, 700, width: 112))
                    Spacer()
                    LiveDot(color: Ink.state(r.state), pulse: r.state == "working")
                    Text(r.state.capitalized).font(SW.a(13, 600)).foregroundStyle(Ink.state(r.state))
                }
                Text(r.text).font(SW.a(14, 500)).fixedSize(horizontal: false, vertical: true)
                if let n = r.note, !n.isEmpty { Text(n).font(SW.a(13.5, 400)).foregroundStyle(Ink.dim).lineLimit(2) }
                ForEach(holding) { t in
                    Text("T\(t.id) \(t.title)" + (t.progress != nil ? " · \(t.progress!)" : "")).font(SW.a(13.5, 400)).foregroundStyle(Ink.runner(r.id)).lineLimit(2)
                }
                Spacer(minLength: 0)
                Text("\(r.detail ?? "")\nSource: \(r.source ?? "none") · last seen \(ago(r.seen))" + ((r.app ?? false) && r.id != "local" ? " · \(Int(r.cpu ?? 0))% CPU" : ""))
                    .font(SW.a(11.5, 400)).foregroundStyle(Ink.faint).lineLimit(3)
            }
            .frame(minHeight: 118, alignment: .topLeading)
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: Store
    var t: BTask
    @State private var open = false

    var meta: String {
        var bits: [String] = []
        if t.isDone { bits.append("done by \(Ink.who(t.holder)) \(ago(t.doneTs ?? t.hb))") }
        else if t.live { bits.append("\(Ink.who(t.holder)) is on it · heartbeat \(ago(t.hb))") }
        else { bits.append("for \(Ink.who(t.forWho))") }
        if let p = t.progress, !p.isEmpty { bits.append(p) }
        if let l = t.location, !l.isEmpty, !t.isDone { bits.append(l) }
        return bits.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text("T\(t.id)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(Ink.runner(t.live || t.isDone ? t.holder : t.forWho))
                    .frame(width: 38, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(SW.a(14, 500)).strikethrough(t.isDone, color: Ink.faint).foregroundStyle(t.isDone ? Ink.dim : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(meta).font(SW.a(13, 400)).foregroundStyle(Ink.dim)
                }
                Spacer()
                if t.live { LiveDot(color: Ink.good, pulse: true) }
                if let d = t.due, !t.isDone { Pill(text: dueText(d), color: t.overdue ? Ink.bad : Ink.dim) }
                Image(systemName: open ? "chevron.up" : "chevron.down").font(SW.a(11.5, 700)).foregroundStyle(Ink.faint).padding(.top, 3)
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if let b = t.body, !b.isEmpty, b != t.title { Text(b).font(SW.a(13.5, 400)).foregroundStyle(Ink.dim).textSelection(.enabled) }
                    if let r = t.result, !r.isEmpty { Text("Result: \(r)").font(SW.a(13.5, 400)).textSelection(.enabled) }
                    if let n = t.note, !n.isEmpty { Text("Note: \(n)").font(SW.a(13.5, 400)).foregroundStyle(Ink.warn) }
                    if let o = t.output, !o.isEmpty {
                        Text(o).font(SW.a(13.5, 400)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.25), in: Rectangle())
                    }
                    if !t.isDone {
                        HStack(spacing: 6) {
                            Menu("Send to") {
                                Button("This Mac (Qwen)") { store.cli(["assign", "T\(t.id)", "local"], quiet: true) }
                                Button("Ultra") { store.cli(["assign", "T\(t.id)", "ultra"], quiet: true) }
                                Button("Pro") { store.cli(["assign", "T\(t.id)", "pro"], quiet: true) }
                                Button("Any runner") { store.cli(["assign", "T\(t.id)", "any"], quiet: true) }
                                Button("Me") { store.cli(["assign", "T\(t.id)", "naren"], quiet: true) }
                                Button("Park it") { store.cli(["assign", "T\(t.id)", "parked"], quiet: true) }
                            }.menuStyle(.borderlessButton).fixedSize()
                            if t.live { Button("Release claim") { store.cli(["release", "T\(t.id)", "released by the owner in the app"], quiet: true) }.buttonStyle(QuietButton()) }
                            Button("Mark done") { store.cli(["done", "T\(t.id)", "marked done by the owner"], quiet: true) }.buttonStyle(QuietButton(color: Ink.good))
                            if let u = t.url, let url = URL(string: u) { Button("Open chat") { NSWorkspace.shared.open(url) }.buttonStyle(QuietButton()) }
                        }
                    }
                }
                .padding(.leading, 48)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
    }
}

struct TaskList: View {
    var tasks: [BTask]
    var empty: String
    var body: some View {
        Card(pad: 12) {
            if tasks.isEmpty { Text(empty).font(SW.a(13.5, 400)).foregroundStyle(Ink.faint) }
            else {
                VStack(spacing: 0) {
                    ForEach(tasks) { t in
                        TaskRow(t: t)
                        if t.id != tasks.last?.id { Divider().overlay(Ink.line) }
                    }
                }
            }
        }
    }
}

struct CommandView: View {
    @EnvironmentObject var store: Store
    var s: Snapshot { store.snap! }
    var moving: [BTask] { s.tasks.filter { $0.live } }
    var next: [BTask] { Array(s.tasks.filter { !$0.isDone && !$0.live && ["any", "ultra", "pro", "local"].contains($0.forWho) }.prefix(6)) }

    var today: [FeedItem] {
        let now = Date().timeIntervalSince1970
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(2 * 86400).timeIntervalSince1970
        return Array((s.feeds["calendar"]?.items ?? []).filter { ($0.end ?? $0.ts ?? 0) >= now && ($0.ts ?? 0) < end }.prefix(5))
    }

    var body: some View {
        Page(title: "Command", subtitle: Date().formatted(.dateTime.weekday(.wide).month(.wide).day()) + " · \(s.counts.working) in motion · \(s.counts.needs + s.counts.naren) waiting on you") {
            TodayHero(done: s.counts.doneToday, total: s.counts.doneToday + s.counts.open)
            AskBar()
            HStack(alignment: .top, spacing: 12) { ForEach(s.runners) { RunnerCard(r: $0) } }
            if s.counts.needs > 0 {
                Heading(text: "Needs you", note: "full list in Needs You")
                NeedsList(limit: 3)
            }
            Heading(text: "In motion")
            TaskList(tasks: moving, empty: "Nothing is claimed right now. Open tasks wait for the next runner that checks in; anything sent to This Mac starts within a second.")
            Heading(text: "Up next", note: "by due date")
            TaskList(tasks: next, empty: "The board is clear.")
            Heading(text: "Next 48 hours")
            Card(pad: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Freshness(feed: s.feeds["calendar"]); Spacer() }
                    if today.isEmpty { Text("Nothing on the calendar.").font(SW.a(13.5, 400)).foregroundStyle(Ink.faint) }
                    ForEach(today) { e in
                        HStack {
                            Text((e.allday ?? false) ? clock(e.ts, "EEE") + " · all day" : clock(e.ts, "EEE · h:mm a")).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(Ink.dim).frame(width: 130, alignment: .leading)
                            Text(e.title).font(SW.a(14, 400))
                            Spacer()
                            Pill(text: e.tag ?? "")
                        }
                    }
                }
            }
        }
    }
}

// MARK: Board
struct BoardView: View {
    @EnvironmentObject var store: Store
    @State private var filter = "open"
    @State private var title = ""
    @State private var forWho = "any"
    @State private var hasDue = false
    @State private var due = Date()

    var tasks: [BTask] {
        let all = store.snap?.tasks ?? []
        switch filter {
        case "moving": return all.filter { $0.live }
        case "naren": return all.filter { !$0.isDone && $0.forWho == "naren" }
        case "parked": return all.filter { !$0.isDone && $0.forWho == "parked" }
        case "done": return all.filter { $0.isDone }
        default: return all.filter { !$0.isDone && !["naren", "parked"].contains($0.forWho) }
        }
    }

    func add() {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var args = ["add", t, "--for", forWho]
        if hasDue { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; args += ["--due", f.string(from: due)] }
        title = ""
        store.cli(args)
    }

    var body: some View {
        let c = store.snap!.counts
        Page(title: "Board", subtitle: "One board for all three runners. A claim is a single database transaction, so two can never hold the same task.") {
            Card(pad: 12) {
                HStack(spacing: 8) {
                    TextField("New task", text: $title).textFieldStyle(.plain).font(SW.a(14, 400)).onSubmit(add)
                    Picker("", selection: $forWho) {
                        Text("Any runner").tag("any"); Text("This Mac").tag("local"); Text("Ultra").tag("ultra"); Text("Pro").tag("pro"); Text("Me").tag("naren")
                    }.labelsHidden().frame(width: 120)
                    Toggle("Due", isOn: $hasDue).toggleStyle(.checkbox)
                    if hasDue { DatePicker("", selection: $due, displayedComponents: .date).labelsHidden() }
                    Button("Add", action: add).buttonStyle(QuietButton(color: Ink.mac))
                }
            }
            Picker("", selection: $filter) {
                Text("Open \(c.open + c.working)").tag("open"); Text("In motion \(c.working)").tag("moving"); Text("Mine \(c.naren)").tag("naren")
                Text("Parked \(c.parked)").tag("parked"); Text("Done").tag("done")
            }.pickerStyle(.segmented).labelsHidden()
            TaskList(tasks: tasks, empty: "Nothing here.")
        }
    }
}

// MARK: Needs You
struct NeedsList: View {
    @EnvironmentObject var store: Store
    var limit = 100
    @State private var answers: [Int: String] = [:]

    var body: some View {
        let s = store.snap!
        let approvals = s.actions.filter { $0.status == "approval" }
        Card(pad: 12) {
            VStack(alignment: .leading, spacing: 10) {
                if s.attention.isEmpty && approvals.isEmpty { Text("No sign-ins, approvals or questions are waiting.").font(SW.a(13.5, 400)).foregroundStyle(Ink.faint) }
                ForEach(approvals.prefix(limit)) { a in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.shield").foregroundStyle(Ink.warn).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(a.summary).font(SW.a(14, 500)).fixedSize(horizontal: false, vertical: true)
                            Text("Asked by \(Ink.who(a.actor)) \(ago(a.ts))").font(SW.a(13, 400)).foregroundStyle(Ink.dim)
                        }
                        Spacer()
                        Button("Approve") { store.cli(["approve", "\(a.id)"], quiet: true) }.buttonStyle(QuietButton(color: Ink.good))
                        Button("Deny") { store.cli(["deny", "\(a.id)"], quiet: true) }.buttonStyle(QuietButton(color: Ink.bad))
                    }
                }
                ForEach(s.attention.prefix(limit)) { n in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: n.kind == "signin" ? "key.horizontal" : (n.kind == "decision" ? "questionmark.bubble" : "bell")).foregroundStyle(Ink.ultra).frame(width: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n.title).font(SW.a(14, 500)).fixedSize(horizontal: false, vertical: true)
                            if let d = n.detail, !d.isEmpty { Text(d).font(SW.a(13.5, 400)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
                            Text("\(n.kind == "signin" ? "Sign-in" : n.kind.capitalized) · from \(Ink.who(n.actor)) \(ago(n.ts))" + (n.task != nil ? " · T\(n.task!)" : "")).font(SW.a(13, 400)).foregroundStyle(Ink.faint)
                            if n.kind == "decision" {
                                HStack {
                                    TextField("Your answer", text: Binding(get: { answers[n.id] ?? "" }, set: { answers[n.id] = $0 })).textFieldStyle(.roundedBorder)
                                    Button("Send") { store.cli(["resolve", "N\(n.id)", answers[n.id] ?? ""], quiet: true) }.buttonStyle(QuietButton(color: Ink.good))
                                }
                            }
                        }
                        Spacer()
                        if let u = n.url, let url = URL(string: u) { Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(QuietButton(color: Ink.ultra)) }
                        if n.kind != "decision" { Button(n.kind == "signin" ? "Signed in" : "Done") { store.cli(["resolve", "N\(n.id)", n.kind == "signin" ? "signed in" : "seen"], quiet: true) }.buttonStyle(QuietButton(color: Ink.good)) }
                    }
                }
            }
        }
    }
}

struct NeedsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let mine = (store.snap?.tasks ?? []).filter { !$0.isDone && $0.forWho == "naren" }
        Page(title: "Needs You", subtitle: "Sign-ins, approvals and decisions only you can make. Runners park them here with everything else already prepared.") {
            NeedsList()
            Heading(text: "Only you can do these", note: "tasks assigned to you")
            TaskList(tasks: mine, empty: "No tasks are assigned to you.")
        }
    }
}
