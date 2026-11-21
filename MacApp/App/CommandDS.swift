import SwiftUI
import AppKit

// Command pane built to the Bridge design system (CommandWindow component, Nov 19, 2026):
// Header (title, date, Today/Week, New task) · hero card (TODAY count + three runner tiles) · Needs you + Feeds · the board.
// Colour only for runner badges, status words with a shape, the accent and the red needs-you count. No borders around cards, no shadows.

enum DS {
    static func a(_ light: UInt32, _ dark: UInt32) -> Color {
        func c(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? c(dark) : c(light) })
    }
    static let bg = a(0xFFFFFF, 0x000000)      // dark: true black, same as the sidebar (a hairline separates them)
    static let surface = a(0xFFFFFF, 0x000000)
    static let raised = a(0xF2F2F2, 0x1E1E1E)
    static let fill = a(0xEEEEEE, 0x2A2A2A)
    static let separator = a(0x000000, 0x303030)
    static let label = a(0x000000, 0xE8E8E8)   // dark: off-white
    static let label2 = a(0x5E5E5E, 0xA8A8A8)
    static let label3 = a(0x86868B, 0x7C7C80)
    static let accent = a(0x000000, 0xE8E8E8)
    static let solid = a(0x000000, 0x262626)   // solid fills: dark grey at night, not white
    static let rule = a(0x000000, 0x333333)    // 2px rules and button borders, dimmed at night
    static let accentSoft = a(0xF2F2F2, 0x1E1E1E)
    static let positive = a(0x1F7A36, 0x30D158)
    static let caution = a(0x8A6100, 0xFFD60A)
    static let critical = a(0xD62E1F, 0xFF453A)
    static let criticalFill = a(0xD62E1F, 0xD62E1F)
    static let ultra = a(0xB85C00, 0xFF9F0A)
    static let pro = a(0x8944AB, 0xBF5AF2)
    static let mac = a(0x007A8F, 0x40C8E0)
    static let you = a(0x000000, 0xFFFFFF)
    static let onRunner = a(0xFFFFFF, 0x000000)
    static let any = a(0x6C6C70, 0x7C7C80)

    static func runner(_ id: String?) -> Color {
        switch id ?? "" { case "ultra": return ultra; case "pro": return pro; case "local": return mac; case "naren": return you; default: return any }
    }
    static func code(_ id: String?) -> String {
        switch id ?? "" { case "ultra": return "ULT"; case "pro": return "PRO"; case "local": return "MAC"; case "naren": return "YOU"; default: return "ANY" }
    }
    static func name(_ id: String?) -> String {
        switch id ?? "" { case "ultra": return "Ultra"; case "pro": return "Pro"; case "local": return "This Mac"; case "naren": return "You"; default: return "Any" }
    }
    /// "2s ago", "4m", "3h", "2d": the board's short ages.
    static func short(_ t: Double?) -> String {
        guard let t, t > 0 else { return "—" }
        let s = max(0, Date().timeIntervalSince1970 - t)
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
    static func caps(_ s: String) -> some View {
        Text(s).font(SW.a(11.5, 700, width: 112)).tracking(0.9).textCase(.uppercase).foregroundStyle(label2)
    }
}

struct DSBadge: View {
    var who: String?
    var big = false
    var off = false
    var body: some View {
        Text(DS.code(who))
            .font(.system(size: big ? 13 : 11, weight: .bold, design: .monospaced)).tracking(0.5)
            .foregroundStyle(off ? DS.label3 : DS.onRunner)
            .frame(width: big ? 44 : 36, height: big ? 26 : 20)
            .background(off ? Color.clear : DS.runner(who), in: Rectangle())
            .overlay(Rectangle().strokeBorder(off ? DS.label3 : .clear, lineWidth: 1.5))
    }
}

struct DSCount: View {
    var n: Int
    var quiet = false
    var body: some View {
        Text("\(n)").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(quiet ? DS.label : .white)
            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
            .background(quiet ? DS.fill : DS.criticalFill, in: Rectangle())
    }
}

struct DSTinted: ButtonStyle {     // bollineni.co .btn: square, 2px black, red when pressed
    func makeBody(configuration: Configuration) -> some View {
        let hot = configuration.isPressed
        configuration.label.font(SW.a(14, 700)).foregroundStyle(hot ? Color.white : DS.label)
            .padding(.horizontal, 14).frame(height: 32)
            .background(hot ? SW.red : Color.clear)
            .overlay(Rectangle().strokeBorder(hot ? SW.red : DS.rule, lineWidth: 2))
            .contentShape(Rectangle())
    }
}

struct DSPrimary: ButtonStyle {    // bollineni.co .btn.solid
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(SW.a(15, 700)).foregroundStyle(Color.white)
            .padding(.horizontal, 20).frame(height: 38)
            .background(configuration.isPressed ? SW.red : DS.solid)
            .contentShape(Rectangle())
    }
}

struct DSSpan: View {
    var value: Double
    var body: some View {
        GeometryReader { g in
            let x = max(7, min(g.size.width - 7, g.size.width * value))
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.label3).frame(height: 2)
                Circle().fill(DS.label3).frame(width: 6, height: 6).offset(x: g.size.width - 6)
                Rectangle().fill(DS.label).frame(width: x, height: 6)
                Circle().fill(DS.surface).frame(width: 20, height: 20).offset(x: x - 10)
                Circle().fill(DS.label).frame(width: 14, height: 14).offset(x: x - 7)
            }
            .frame(height: 20)
        }
        .frame(height: 20)
    }
}

// MARK: the pane

struct CommandDSView: View {
    @EnvironmentObject var store: Store
    @State private var range = "today"
    @State private var newTask = false
    var s: Snapshot { store.snap! }

    var startOfDay: Double { Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 }
    var since: Double { range == "today" ? startOfDay : startOfDay - 6 * 86400 }
    var doneInRange: [BTask] { s.tasks.filter { $0.isDone && ($0.doneTs ?? 0) >= since }.sorted { ($0.doneTs ?? 0) > ($1.doneTs ?? 0) } }
    var openTasks: [BTask] { s.tasks.filter { !$0.isDone && !$0.live && $0.forWho != "parked" } }
    var doneCount: Int { range == "today" ? s.counts.doneToday : doneInRange.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hero
                HStack(alignment: .top, spacing: 16) {
                    needs.frame(maxWidth: .infinity)
                    feeds.frame(maxWidth: .infinity)
                }
                board
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.bg)
        .sheet(isPresented: $newTask) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New task").font(SW.heading(22)).tracking(-0.8)
                AskBar()
                HStack { Spacer(); Button("Done") { newTask = false }.keyboardShortcut(.cancelAction) }
            }
            .padding(20).frame(width: 640)
        }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Command").font(SW.display(34)).tracking(-1.6)
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(SW.a(15, 400)).foregroundStyle(DS.label2)
            }
            Spacer()
            DSSegmented(value: $range, options: [("today", "Today"), ("week", "Week")])
            Button("New task") { newTask = true }.buttonStyle(DSPrimary())
        }
        .frame(minHeight: 44)
    }

    // TODAY count and the three runners
    var hero: some View {
        let total = doneCount + openTasks.count + s.tasks.filter { $0.live }.count
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: range == "today" ? "Today" : "This week")
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(doneCount)").font(.system(size: 72, weight: .bold, design: .rounded)).tracking(-3).monospacedDigit()
                        .contentTransition(.numericText()).animation(Civic.ease, value: doneCount)
                    Text("of \(total) done").font(SW.a(15, 400)).foregroundStyle(DS.label2)
                }
                .frame(height: 66, alignment: .bottom)
                DSSpan(value: total == 0 ? 0 : Double(doneCount) / Double(total)).animation(Civic.ease, value: doneCount)
            }
            .frame(width: 240)
            HStack(spacing: 8) { ForEach(["ultra", "pro", "local"], id: \.self) { RunnerTileDS(id: $0) } }
        }
        .padding(16)
        .background(DS.surface, in: Rectangle())
    }

    // Needs you: approvals, sign-ins and decisions, then tasks only the owner can do
    struct NeedRow: Identifiable { var id: String; var title: String; var sub: String; var button: String; var run: () -> Void }
    var needRows: [NeedRow] {
        var r: [NeedRow] = []
        for a in s.actions where a.status == "approval" {
            r.append(NeedRow(id: "a\(a.id)", title: a.summary, sub: (a.task.map { "T\($0) · " } ?? "") + "\(DS.name(a.actor)) asked \(DS.short(a.ts)) ago", button: "Approve") { store.cli(["approve", "\(a.id)"], quiet: true) })
        }
        for n in s.attention {
            let url = n.url.flatMap { URL(string: $0) }
            r.append(NeedRow(id: "n\(n.id)", title: n.title, sub: (n.task.map { "T\($0) · " } ?? "") + ((n.detail ?? "").isEmpty ? "from \(DS.name(n.actor)) · \(DS.short(n.ts)) ago" : n.detail!), button: url != nil ? "Open" : (n.kind == "signin" ? "Signed in" : "Done")) {
                if let u = url { NSWorkspace.shared.open(u) } else { store.cli(["resolve", "N\(n.id)", n.kind == "signin" ? "signed in" : "seen"], quiet: true) }
            })
        }
        for t in s.tasks where !t.isDone && t.forWho == "naren" {
            r.append(NeedRow(id: "t\(t.id)", title: t.title, sub: "T\(t.id)" + (t.due != nil ? " · due \(dueText(t.due))" : "") + (t.overdue ? " · overdue" : ""), button: t.url != nil ? "Open" : "Done") {
                if let u = t.url.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(u) } else { store.cli(["done", "T\(t.id)", "marked done by the owner"], quiet: true) }
            })
        }
        return r
    }

    var needs: some View {
        let rows = needRows
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DS.caps("Needs you")
                if !rows.isEmpty { DSCount(n: rows.count) }
                Spacer()
                Button("Show all") { store.requestedPane = "needs" }.buttonStyle(.plain).font(SW.a(15, 600)).foregroundStyle(DS.accent)
            }
            .padding(.horizontal, 16).frame(height: 22)
            VStack(spacing: 0) {
                if rows.isEmpty { Text("All clear.").font(SW.a(15, 400)).foregroundStyle(DS.label2).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 16) }
                ForEach(Array(rows.prefix(3).enumerated()), id: \.element.id) { i, n in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.title).font(SW.a(17, 400)).lineLimit(1)
                            Text(n.sub).font(SW.a(13, 400)).foregroundStyle(DS.label2).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button(n.button, action: n.run).buttonStyle(DSTinted())
                    }
                    .padding(.horizontal, 16).frame(minHeight: 60)
                    .overlay(alignment: .bottom) { if i < min(rows.count, 3) - 1 { Rectangle().fill(DS.separator).frame(height: 0.5).padding(.leading, 16) } }
                }
            }
            .background(DS.surface, in: Rectangle())
        }
    }

    // Feeds: name, then Live · age or Stale · age
    var feeds: some View {
        let order: [(String, String, String)] = [("calendar", "Calendar", "calendar"), ("mail", "Mail", "envelope"), ("messages", "Messages", "message"), ("reminders", "Reminders", "checklist"), ("notes", "Notes", "note.text")]
        let shown = order.filter { s.feeds[$0.0] != nil }
        return VStack(alignment: .leading, spacing: 8) {
            DS.caps("Feeds").padding(.horizontal, 16).frame(height: 22)
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.0) { i, f in
                    let feed = s.feeds[f.0]!
                    Button { store.requestedPane = f.0 } label: {
                        HStack(spacing: 12) {
                            Image(systemName: f.2).font(SW.a(14, 500)).foregroundStyle(DS.label)
                                .frame(width: 30, height: 30).background(DS.fill, in: Rectangle())
                            Text(f.1).font(SW.a(17, 400)).foregroundStyle(DS.label)
                            Spacer()
                            if feed.fresh {
                                Circle().fill(DS.positive).frame(width: 8, height: 8)
                                Text("Live · \(DS.short(feed.asOf)) ago").font(SW.a(15, 400)).foregroundStyle(DS.positive)
                            } else {
                                Rectangle().fill(DS.caution).frame(width: 7, height: 7).rotationEffect(.degrees(45))
                                Text("Stale · \(DS.short(feed.asOf))").font(SW.a(15, 400)).foregroundStyle(DS.caution)
                            }
                        }
                        .padding(.horizontal, 16).frame(height: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { if i < shown.count - 1 { Rectangle().fill(DS.separator).frame(height: 0.5).padding(.leading, 58) } }
                }
            }
            .background(DS.surface, in: Rectangle())
        }
    }

    // The board: WHO · ID · TASK · STATUS · TIME
    var boardRows: [BTask] {
        let live = s.tasks.filter { $0.live }
        let open = openTasks.sorted { ($0.due ?? "9999") < ($1.due ?? "9999") }
        return Array((live + open.prefix(4) + doneInRange.prefix(2)).prefix(9))
    }

    var board: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DS.caps("Who").frame(width: 56, alignment: .leading)
                DS.caps("ID").frame(width: 62, alignment: .leading)
                DS.caps("Task")
                Spacer()
                DS.caps("Status").frame(width: 100, alignment: .trailing)
                DS.caps("Time").frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 16).frame(height: 36)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.separator).frame(height: 0.5) }
            if boardRows.isEmpty { Text("Nothing queued.").font(SW.a(15, 400)).foregroundStyle(DS.label2).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, 16) }
            ForEach(Array(boardRows.enumerated()), id: \.element.id) { i, t in
                BoardRowDS(t: t)
                    .overlay(alignment: .bottom) { if i < boardRows.count - 1 { Rectangle().fill(DS.separator).frame(height: 0.5).padding(.leading, 16) } }
            }
        }
        .background(DS.surface, in: Rectangle())
    }
}

struct RunnerTileDS: View {
    @EnvironmentObject var store: Store
    var id: String
    var body: some View {
        let s = store.snap!
        let r = s.runners.first { $0.id == id }
        let state = r?.state ?? "unknown"
        let held = s.tasks.first { $0.live && $0.holder == id }
        let probeTask = r?.probe?.running?.first
        let title = held?.title ?? probeTask ?? "Nothing held"
        let working = state == "working"
        let quiet = held == nil && probeTask == nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DSBadge(who: id, big: true, off: ["offline", "unknown"].contains(state))
                Text(DS.name(id)).font(SW.a(17, 600))
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SW.a(15, 400)).foregroundStyle(quiet ? DS.label2 : DS.label).lineLimit(1).truncationMode(.tail)
                HStack {
                    Text((held.map { "T\($0.id) · " } ?? "") + state.capitalized).font(SW.a(15, 400)).foregroundStyle(DS.label2).lineLimit(1)
                    Spacer(minLength: 4)
                    if working, let t = r?.since ?? held?.hb {
                        Text(Date(timeIntervalSince1970: t), style: .timer).font(.system(size: 15, weight: .semibold, design: .monospaced)).monospacedDigit()
                            .multilineTextAlignment(.trailing).frame(width: 64, alignment: .trailing)
                    } else {
                        Text(DS.short(r?.since ?? r?.seen)).font(.system(size: 15, design: .monospaced)).foregroundStyle(DS.label2)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.raised, in: Rectangle())
        .contentShape(Rectangle())
        .onTapGesture { AppDelegate.shared?.route(URL(string: "bridge://open/\(id)")!) }
    }
}

struct BoardRowDS: View {
    @EnvironmentObject var store: Store
    var t: BTask
    var body: some View {
        let who = t.live || t.isDone ? t.holder : t.forWho
        let runnerState = store.snap?.runners.first { $0.id == t.holder }?.state
        let status: String = t.isDone ? "Done" : (t.live ? (runnerState == "working" ? "Working" : "Holding") : (t.forWho == "naren" ? "Needs you" : (t.overdue ? "Overdue" : "Open")))
        HStack(spacing: 0) {
            DSBadge(who: who).frame(width: 56, alignment: .leading)
            Text("T\(t.id)").font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(t.isDone ? DS.label2 : DS.label).frame(width: 62, alignment: .leading)
            Text(t.title).font(SW.a(17, 400)).foregroundStyle(t.isDone ? DS.label2 : DS.label).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            Text(status).font(.system(size: 15, weight: status == "Working" ? .semibold : .regular))
                .foregroundStyle(status == "Working" ? DS.label : (status == "Overdue" ? DS.critical : DS.label2)).frame(width: 100, alignment: .trailing)
            Group {
                if status == "Working", let h = t.hb ?? t.created {
                    Text(Date(timeIntervalSince1970: store.snap?.runners.first { $0.id == t.holder }?.since ?? h), style: .timer).multilineTextAlignment(.trailing)
                } else if t.isDone {
                    Text(clock(t.doneTs, "h:mm a"))
                } else if t.live {
                    Text(DS.short(t.hb))
                } else {
                    Text(t.due.map { dueShort($0) } ?? "—")
                }
            }
            .font(.system(size: 15, design: .monospaced)).monospacedDigit().foregroundStyle(DS.label2).frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16).frame(height: 52)
        .contentShape(Rectangle())
        .onTapGesture { store.requestedPane = "board" }
    }
    func dueShort(_ d: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: d) else { return d }
        f.dateFormat = "MMM d"; return f.string(from: date)
    }
}
