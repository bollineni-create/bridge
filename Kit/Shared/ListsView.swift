import SwiftUI

// MARK: Needs you
struct NeedsView: View {
    @EnvironmentObject var s: Store
    var showTitle = true
    var body: some View {
        let all = s.needs
        let mine = all.filter { $0.kind != .approval }
        let groups: [(String, [NeedItem])] = [
            ("Today", mine.filter { $0.kind == .need || dueDays($0.due) <= 0 }),
            ("This week", mine.filter { $0.kind == .task && (1...7).contains(dueDays($0.due)) }),
            ("Later", mine.filter { $0.kind == .task && dueDays($0.due) > 7 }),
            ("Approvals", s.approvals),
        ].filter { !$0.1.isEmpty }
        Scroller {
            VStack(alignment: .leading, spacing: 0) {
                if showTitle { PageTitle(title: "Needs you", sub: "Only decisions you can make", count: all.count).padding(.bottom, 8) }
                if all.isEmpty {
                    EmptyNote(text: "Nothing needs you.", sub: "Ultra, Pro and Qwen are covering it.")
                }
                ForEach(groups, id: \.0) { g in
                    Eyebrow(text: g.0).padding(.top, 22).padding(.bottom, 10)
                    Rule(heavy: true)
                    ForEach(g.1) { n in NeedRow(n: n); Rule() }
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
        }
    }
}

struct NeedRow: View {
    @EnvironmentObject var s: Store
    var n: NeedItem
    var meta: String { [dueText(n.due), n.detail].filter { !$0.isEmpty }.joined(separator: " · ") }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(n.code).font(D.monoSmall).foregroundStyle(D.quiet).frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title).font(D.a(15, 500)).foregroundStyle(D.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if !meta.isEmpty { Text(meta).font(D.a(12.5)).foregroundStyle(dueDays(n.due) < 0 ? D.red : D.quiet).lineLimit(2) }
            }
            Spacer(minLength: 6)
            if s.busy.contains(n.id) {
                ProgressView().controlSize(.small).frame(width: 96)
            } else {
                HStack(spacing: 2) {
                    Button(n.kind == .approval ? "Approve" : "Done") { s.complete(n) }.buttonStyle(SquareButton(solid: true))
                    if n.kind == .approval { Button("Deny") { s.deny(n) }.buttonStyle(SquareButton(quiet: true)) }
                    else {
                        Button("Reply") { s.replyItem = n }.buttonStyle(SquareButton())
                        Button("Open") { s.open(n) }.buttonStyle(SquareButton(quiet: true))
                    }
                }
                .lineLimit(1).fixedSize()
            }
        }
        .padding(.vertical, 14)
    }
}

// MARK: Board
struct BoardView: View {
    @EnvironmentObject var s: Store
    @State private var seg = "Moving"
    @State private var picked: BTask?
    var showTitle = true
    let segs = ["Moving", "Open", "Mine", "Done"]
    var rows: [BTask] {
        let t = s.tasks.map { x -> BTask in var y = x; if s.settled.contains("T\(x.id)") { y.status = "done" }; return y }
        switch seg {
        case "Moving": return t.filter { !$0.isDone && ($0.live ?? false) }
        case "Open": return t.filter { !$0.isDone && !["naren", "parked"].contains($0.forWho ?? "") }.sorted { dueDays($0.due) < dueDays($1.due) }
        case "Mine": return t.filter { !$0.isDone && $0.forWho == "naren" }.sorted { dueDays($0.due) < dueDays($1.due) }
        default: return Array(t.filter { $0.isDone }.sorted { ($0.doneTs ?? 0) > ($1.doneTs ?? 0) }.prefix(40))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTitle { PageTitle(title: "Board").padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 14) }
            UnderlineTabs(items: segs, selected: $seg).padding(.horizontal, 24)
            let list = rows
            if list.isEmpty {
                EmptyNote(text: seg == "Moving" ? "Nothing is moving." : "Empty.", sub: seg == "Moving" ? "Open tasks start when a runner checks in." : "")
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                Scroller {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Eyebrow(text: "ID").frame(width: 40, alignment: .leading)
                            Eyebrow(text: "Task"); Spacer()
                            Eyebrow(text: "Who").frame(width: 48, alignment: .leading)
                            Eyebrow(text: "Due").frame(width: 56, alignment: .trailing)
                        }.padding(.top, 22).padding(.bottom, 8)
                        Rule(heavy: true)
                        ForEach(list) { t in
                            Button { picked = t } label: { BoardRow(t: t, showResult: seg == "Done") }.buttonStyle(.plain)
                            Rule()
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 16)
                }
            }
        }
        .sheet(item: $picked) { t in TaskSheet(t: t).environmentObject(s) }
        .onAppear { takeJump() }
        .onChange(of: s.boardJump) { _, _ in takeJump() }
    }
    private func takeJump() {
        if let j = s.boardJump, segs.contains(j) { seg = j }
        if s.boardJump != nil { s.boardJump = nil }
    }
}

struct BoardRow: View {
    var t: BTask
    var showResult = false
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("T\(t.id)").font(D.monoSmall).foregroundStyle(D.quiet).frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(clean(t.title)).font(D.a(15, 500)).foregroundStyle(t.isDone ? D.quiet : D.ink).lineLimit(2).multilineTextAlignment(.leading)
                if showResult, let r = t.result, !r.isEmpty { Text(r).font(D.a(12.5)).foregroundStyle(D.quiet).lineLimit(2) }
                else if (t.live ?? false), let p = t.progress, !p.isEmpty { Text(p).font(D.a(12.5)).foregroundStyle(D.body).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Badge(who: t.holder ?? t.forWho, filled: t.live ?? false).frame(width: 48, alignment: .leading)
            Text(t.isDone ? "Done" : dueText(t.due)).font(D.a(13)).foregroundStyle((t.overdue ?? false) ? D.red : D.quiet).frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 14).contentShape(Rectangle())
    }
}

/// Task detail: the site's row style, with the output when there is one.
struct TaskSheet: View {
    @EnvironmentObject var s: Store
    @Environment(\.dismiss) var dismiss
    var t: BTask
    @State private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("T\(t.id)").font(D.mono).foregroundStyle(D.ink)
                Text(t.isDone ? "Done" : ((t.live ?? false) ? "Moving" : "Open")).font(D.a(13)).foregroundStyle(D.quiet)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(SquareButton(quiet: true))
            }.padding(.bottom, 14)
            Rule(heavy: true)
            Scroller {
                VStack(alignment: .leading, spacing: 14) {
                    Text(clean(t.title)).font(D.heading(24)).tracking(-1).foregroundStyle(D.ink).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Badge(who: t.holder ?? t.forWho, filled: t.live ?? false)
                        Text(D.name(t.holder ?? t.forWho)).font(D.a(14, 600))
                        Spacer()
                        Text(dueText(t.due)).font(D.a(14)).foregroundStyle(D.quiet)
                    }
                    if let r = t.result, !r.isEmpty { Rule(); Eyebrow(text: "Result"); Text(r).font(D.a(15)).foregroundStyle(D.body).textSelection(.enabled) }
                    if let o = t.output, let text = s.backend.readOutput(o) { Rule(); Eyebrow(text: "Output"); Text(text).font(D.a(14)).foregroundStyle(D.body).textSelection(.enabled) }
                    else if let p = t.progress, !p.isEmpty { Rule(); Eyebrow(text: "Progress"); Text(p).font(D.a(15)).foregroundStyle(D.body) }
                }.padding(.vertical, 16)
            }
            if !t.isDone {
                Rule()
                HStack(spacing: 8) {
                    TextField("Reply to Claude…", text: $answer, axis: .vertical)
                        .textFieldStyle(.plain).font(D.a(14.5)).lineLimit(1...5)
                        .padding(8).overlay(Rectangle().strokeBorder(D.ink, lineWidth: 2))
                    Button("Send") { s.reply("T\(t.id)", answer); dismiss() }
                        .buttonStyle(SquareButton()).disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(.top, 14)
                HStack(spacing: 8) {
                    if t.forWho != "local" { Button("Assign to Mac") { s.act(["assign", "T\(t.id)", "local"], key: "T\(t.id)", ok: "T\(t.id) → Mac"); dismiss() }.buttonStyle(SquareButton()) }
                    Spacer()
                    Button("Done") { s.act(["done", "T\(t.id)", "Done in Bridge"], key: "T\(t.id)", ok: "T\(t.id) done"); dismiss() }.buttonStyle(SquareButton(solid: true))
                }.padding(.top, 14)
            }
        }
        .padding(24)
        .frame(minWidth: 360, idealWidth: 420, minHeight: 420)
        .background(D.paper)
    }
}

/// Answer a Needs-you item: a decision is answered in place; a task goes back to Claude with the answer.
struct ReplySheet: View {
    @EnvironmentObject var s: Store
    @Environment(\.dismiss) var dismiss
    var n: NeedItem
    @State private var text = ""
    @FocusState private var focused: Bool
    var isTask: Bool { !n.id.hasPrefix("N") }
    var ready: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(n.code).font(D.mono).foregroundStyle(D.ink)
                Text("Reply").font(D.a(13)).foregroundStyle(D.quiet)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(SquareButton(quiet: true))
            }.padding(.bottom, 14)
            Rule(heavy: true)
            Text(n.title).font(D.heading(22)).tracking(-1).foregroundStyle(D.ink)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 14)
            if !n.detail.isEmpty { Text(n.detail).font(D.a(14)).foregroundStyle(D.quiet).padding(.bottom, 12) }
            TextField(isTask ? "Your answer, e.g. \"keep it\" or \"cancel it\"" : "Your answer", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(D.a(15)).lineLimit(3...8)
                .padding(10).overlay(Rectangle().strokeBorder(D.ink, lineWidth: 2))
                .focused($focused)
            Text(isTask ? "Claude picks the task back up with your answer." : "Your answer goes to whoever asked.")
                .font(D.a(12.5)).foregroundStyle(D.quiet).padding(.top, 8)
            Spacer(minLength: 14)
            HStack {
                Spacer()
                Button(isTask ? "Send to Claude" : "Send answer") { s.reply(n.id, text); dismiss() }
                    .buttonStyle(SquareButton(solid: true)).disabled(!ready).opacity(ready ? 1 : 0.4)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(minWidth: 360, idealWidth: 460, minHeight: 340)
        .background(D.paper)
        .onAppear { focused = true }
    }
}

struct EmptyNote: View {
    var text: String
    var sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(D.heading(20)).tracking(-0.6).foregroundStyle(D.ink)
            if !sub.isEmpty { Text(sub).font(D.a(14)).foregroundStyle(D.quiet) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 28)
    }
}
