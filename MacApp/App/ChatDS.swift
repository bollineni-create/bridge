import SwiftUI
import AppKit

// Bridge Chat: the main way to drive every runner. One box; Bridge routes each message (or splits it), lets you pick the
// Claude model and effort, sends each part to the right runner, and brings every answer back here. Engine: bridge_convo.py.

struct Convo: Decodable, Identifiable, Equatable {
    var id: Int
    var title: String
    var updated: Double?
    var runner: String
    var chat: String
    var model: String
    var effort: String
    var status: String
    var msgs: [ConvoMsg]
    var steps: [ConvoStep]
}

struct ConvoMsg: Decodable, Identifiable, Equatable {
    var id: Int
    var ts: Double?
    var role: String          // user | runner | bridge
    var runner: String
    var kind: String          // text | plan | result | question | summary | error | status
    var text: String
    var task: Int?
    var turn: Int?
    var state: String
    var options: [String]? = nil     // kind "permission": the card's buttons, in Claude's order
}

struct ConvoStep: Decodable, Identifiable, Equatable {
    var id: Int
    var turn: Int?
    var idx: Int
    var title: String
    var runner: String
    var status: String        // pending | queued | working | done | failed | cancelled
    var task: Int?
    var model: String
    var effort: String
    var after: [Int]
    var why: String
    var chat: String
    var progress: String
    var split: Bool
}

struct ConvoOptions: Decodable {
    var models: [String]
    var efforts: [String]
    var runners: [ConvoRunner]
}

struct ConvoRunner: Decodable, Identifiable {
    var id: String
    var name: String
    var kind: String
}

private func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct ChatDSView: View {
    @EnvironmentObject var store: Store
    @State private var selected: Int? = nil          // nil = a new chat
    @State private var draft = ""
    @State private var who = "auto"
    @State private var model = ""                    // "" = Bridge picks
    @State private var effort = ""
    @State private var pending: [String] = []        // sent, not yet in the snapshot
    @State private var sending = false
    @FocusState private var typing: Bool

    var convos: [Convo] { store.snap?.convos ?? [] }
    var current: Convo? { convos.first { $0.id == selected } }
    var options: ConvoOptions? { store.snap?.convo_options }
    var claudeRunners: Set<String> { Set((options?.runners ?? []).filter { $0.kind != "local-model" }.map(\.id)) }
    var modelApplies: Bool { who != "local" && (who == "auto" || who == "split" || claudeRunners.contains(who)) }
    let starters = [
        ("What's on my calendar this week?", "auto"),
        ("Draft a reply to my latest email", "auto"),
        ("Review the newest commits in bridge-public and fix anything broken", "auto"),
        ("1. Summarize my unread messages\n2. Research the best Seattle apartments under $1,700", "split"),
    ]

    func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        var args = ["convo", "send", selected.map { "C\($0)" } ?? "new", t, "--who", who]
        if modelApplies && !model.isEmpty { args += ["--model", model] }
        if modelApplies && !effort.isEmpty { args += ["--effort", effort] }
        draft = ""
        pending.append(t)
        sending = true
        store.cli(args, quiet: true) { ok, out in
            sending = false
            guard ok, let d = out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = j["convo"] as? Int else {
                pending.removeAll { $0 == t }; draft = t; store.say(out); return
            }
            selected = id
            store.probeNow = true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            threadList.frame(width: 248)
            Rectangle().fill(DS.separator.opacity(0.25)).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(DS.separator.opacity(0.15)).frame(height: 1)
                conversation
                composer
            }
            .background(DS.bg)
        }
        .onAppear { typing = true; if selected == nil { selected = convos.first(where: { $0.status != "idle" })?.id } }
        .onChange(of: current?.msgs.count) { _, _ in
            if let c = current { pending.removeAll { p in c.msgs.contains { $0.role == "user" && $0.text == p } } }
        }
    }

    // MARK: threads
    var threadList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { selected = nil; who = "auto"; model = ""; effort = ""; typing = true } label: {
                HStack { Image(systemName: "square.and.pencil"); Text("New chat").font(SW.a(14, 600)); Spacer(); Text("⌘N").font(SW.a(11, 500)).foregroundStyle(DS.label3) }
                    .padding(.horizontal, 12).frame(height: 36).overlay(Rectangle().strokeBorder(DS.rule, lineWidth: 2)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut("n", modifiers: .command)
            RunnerStrip()
            DS.caps("Chats").padding(.top, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(convos) { c in
                        Button { selected = c.id; typing = true } label: {
                            HStack(spacing: 8) {
                                statusMark(c)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).font(SW.a(13.5, selected == c.id ? 600 : 400)).lineLimit(1)
                                    Text(sub(c)).font(SW.a(11.5, 400)).foregroundStyle(DS.label3).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .background(selected == c.id ? DS.fill : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Stop all parts") { store.cli(["convo", "stop", "C\(c.id)"], quiet: true) }.disabled(c.status != "working")
                            Button("Delete chat", role: .destructive) { if selected == c.id { selected = nil }; store.cli(["convo", "delete", "C\(c.id)"], quiet: true) }
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    func sub(_ c: Convo) -> String {
        let who = c.runner.isEmpty ? "" : DS.name(c.runner)
        switch c.status {
        case "working": return "working" + (who.isEmpty ? "" : " · \(who)")
        case "waiting": return "\(who.isEmpty ? "A runner" : who) is asking you"
        default: return [who, ago(c.updated)].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @ViewBuilder func statusMark(_ c: Convo) -> some View {
        if c.status == "working" { LiveDot(color: DS.runner(c.runner.isEmpty ? nil : c.runner), pulse: true).frame(width: 10) }
        else if c.status == "waiting" { Circle().fill(SW.red).frame(width: 8, height: 8).frame(width: 10) }
        else { Circle().fill(DS.label3.opacity(0.35)).frame(width: 6, height: 6).frame(width: 10) }
    }

    // MARK: header
    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(current?.title ?? "New chat").font(SW.heading(22)).lineLimit(1)
                Text(headerSub).font(SW.a(12.5, 400)).foregroundStyle(DS.label2).lineLimit(1)
            }
            Spacer()
            if let c = current, c.status != "working", !c.msgs.isEmpty {
                Menu {
                    ForEach((options?.runners ?? []).filter { $0.id != c.runner }) { r in
                        Button(r.name) { store.cli(["convo", "send", "C\(c.id)", "Continue this conversation and finish it.", "--who", r.id], quiet: true) }
                    }
                } label: { Label("Hand off", systemImage: "arrowshape.turn.up.right") }
                    .menuStyle(.borderlessButton).fixedSize().help("Give this whole conversation to another runner")
            }
            if current?.status == "working" {
                Button { if let c = current { store.cli(["convo", "stop", "C\(c.id)"], quiet: true) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(QuietButton(color: SW.red))
            }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
    }

    var headerSub: String {
        guard let c = current else { return "Bridge routes it to Ultra, Pro or Qwen on this Mac, or splits it across them, and reports back here." }
        var bits: [String] = []
        if !c.runner.isEmpty { bits.append("with \(DS.name(c.runner))") }
        if !c.chat.isEmpty { bits.append("Claude chat “\(c.chat)”") }
        if !c.model.isEmpty { bits.append(c.model + (c.effort.isEmpty ? "" : " · \(c.effort)")) }
        return bits.isEmpty ? "C\(c.id)" : bits.joined(separator: " · ")
    }

    // MARK: conversation
    var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let c = current {
                        ForEach(c.msgs) { m in
                            MsgView(m: m, steps: c.steps.filter { $0.turn == m.turn }).id(m.id)
                        }
                    } else if pending.isEmpty {
                        empty
                    }
                    ForEach(pending, id: \.self) { p in MsgView(m: ConvoMsg(id: -1, ts: nil, role: "user", runner: "", kind: "text", text: p, task: nil, turn: nil, state: "sending"), steps: []) }
                    if let c = current, c.status == "working", c.msgs.last?.role == "user" || c.msgs.last?.kind == "plan" {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(workingLine(c)).font(SW.a(12.5, 400)).foregroundStyle(DS.label2) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .onChange(of: current?.msgs.last?.id) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: pending.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: selected) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    func workingLine(_ c: Convo) -> String {
        let live = c.steps.filter { ["pending", "queued", "working"].contains($0.status) }
        if live.isEmpty { return "Bridge is working out who should take this…" }
        return live.map { "\(DS.name($0.runner)) \($0.status == "working" ? "is on it" : "has it queued")" }.joined(separator: " · ")
    }

    var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One chat for every runner.").font(SW.display(30)).tracking(-1)
            Text("Type anything. Bridge sends it to the runner that fits (Qwen on this Mac when it can, Pro for code, Ultra for the web and judgment calls), splits it when the parts are separate, and brings every answer back here. Pick a runner, a model or an effort below to override it.")
                .font(SW.a(14, 400)).foregroundStyle(DS.label2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(starters, id: \.0) { s in
                    Button { draft = s.0; who = s.1; send() } label: {
                        HStack { Text(s.0.replacingOccurrences(of: "\n", with: "  ")).font(SW.a(13.5, 500)).lineLimit(1); Spacer(); if s.1 == "split" { Text("SPLIT").font(SW.a(10.5, 700)).foregroundStyle(DS.label3) } }
                            .padding(.horizontal, 12).padding(.vertical, 9).overlay(Rectangle().strokeBorder(DS.separator.opacity(0.3), lineWidth: 1)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 50)
    }

    // MARK: composer
    var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = current, !c.runner.isEmpty, who == "auto" {
                Text(followHint(c)).font(SW.a(11.5, 400)).foregroundStyle(DS.label3)
            }
            VStack(spacing: 0) {
                TextField(current == nil ? "Message all your runners" : "Reply", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(SW.a(15, 400)).lineLimit(1...10).focused($typing)
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                    .onSubmit(send)
                HStack(spacing: 6) {
                    picker(label: whoLabel, icon: "arrow.triangle.branch") {
                        Button("Auto · Bridge decides") { who = "auto" }
                        Button("Split across runners") { who = "split" }
                        Divider()
                        ForEach(options?.runners ?? []) { r in Button(r.name + (r.kind == "local-model" ? " · this Mac, free" : "")) { who = r.id } }
                    }
                    if modelApplies {
                        picker(label: model.isEmpty ? "Auto model" : model, icon: "cpu") {
                            Button("Auto · Bridge picks") { model = "" }
                            Divider()
                            ForEach(options?.models ?? ["Haiku 5.5", "Sonnet 5.5", "Opus 5.5"], id: \.self) { m in Button(m) { model = m } }
                        }
                        picker(label: effort.isEmpty ? "Auto effort" : effort.capitalized, icon: "gauge.with.dots.needle.50percent") {
                            Button("Auto · Bridge picks") { effort = "" }
                            Divider()
                            ForEach(options?.efforts ?? ["low", "medium", "high"], id: \.self) { e in Button(e.capitalized + (e == "max" ? " (uses the most)" : "")) { effort = e } }
                        }
                    }
                    Spacer()
                    Button(action: send) {
                        Image(systemName: sending ? "hourglass" : "arrow.up").font(SW.a(15, 700)).foregroundStyle(DS.onRunner)
                            .frame(width: 34, height: 34).background(draft.trimmingCharacters(in: .whitespaces).isEmpty ? DS.label3 : DS.accent)
                    }
                    .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            .background(DS.raised)
            .overlay(Rectangle().strokeBorder(DS.rule.opacity(0.6), lineWidth: 1))
        }
        .padding(.horizontal, 24).padding(.bottom, 18).padding(.top, 6).frame(maxWidth: 900).frame(maxWidth: .infinity)
    }

    var whoLabel: String {
        switch who {
        case "auto": return "Auto"
        case "split": return "Split"
        default: return options?.runners.first { $0.id == who }?.name ?? DS.name(who)
        }
    }

    func followHint(_ c: Convo) -> String {
        let r = DS.name(c.runner)
        return c.chat.isEmpty ? "Replies go to \(r), keeping this conversation's context. Pick another runner (or Hand off) to switch; the conversation goes with it."
                              : "Replies continue in \(r)'s chat “\(c.chat)”. Pick another runner (or Hand off) to switch; the conversation goes with it."
    }

    func picker<Content: View>(label: String, icon: String, @ViewBuilder _ items: () -> Content) -> some View {
        Menu { items() } label: {
            HStack(spacing: 5) { Image(systemName: icon).font(SW.a(11, 500)); Text(label).font(SW.a(12.5, 600)); Image(systemName: "chevron.down").font(SW.a(9, 700)) }
                .padding(.horizontal, 9).frame(height: 28).background(DS.fill)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: one message
struct MsgView: View {
    @EnvironmentObject var store: Store
    var m: ConvoMsg
    var steps: [ConvoStep]
    @State private var expanded = false

    var body: some View {
        switch m.role {
        case "user":
            HStack {
                Spacer(minLength: 120)
                Text(md(m.text)).font(SW.a(14.5, 400)).foregroundStyle(DS.onRunner).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10).background(DS.accent.opacity(m.state == "sending" ? 0.55 : 1))
            }
        case "bridge" where m.kind == "plan":
            PlanView(text: m.text, steps: steps)
        case "runner" where m.kind == "permission":
            PermissionCard(m: m)
        case "bridge" where m.kind == "status":
            Text(m.text).font(SW.a(12, 400)).foregroundStyle(DS.label3)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(m.role == "bridge" ? (m.kind == "summary" ? "REPORT" : "BRIDGE") : DS.code(m.runner)).font(SW.a(10.5, 800)).tracking(0.6)
                        .foregroundStyle(DS.onRunner).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(m.role == "bridge" ? DS.solid : DS.runner(m.runner))
                    Text(caption).font(SW.a(11.5, 500)).foregroundStyle(DS.label3)
                    Spacer()
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.text, forType: .string) } label: { Image(systemName: "doc.on.doc").font(SW.a(11, 500)) }
                        .buttonStyle(.plain).foregroundStyle(DS.label3).help("Copy")
                }
                Text(md(shown)).font(SW.a(14.5, 400)).foregroundStyle(m.kind == "error" ? DS.critical : DS.label).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if long {
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }.buttonStyle(.plain).font(SW.a(12, 600)).foregroundStyle(DS.label2)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) { Rectangle().fill(m.kind == "question" ? SW.red : (m.role == "bridge" ? DS.label3 : DS.runner(m.runner))).frame(width: 3) }
        }
    }

    var long: Bool { m.text.count > 2400 }
    var shown: String { long && !expanded ? String(m.text.prefix(2400)) + "…" : m.text }
    var caption: String {
        var bits: [String] = []
        switch m.kind {
        case "question": bits.append("is asking you · reply below")
        case "summary": bits.append("everything that came back")
        case "error": bits.append("problem")
        default: if m.role == "runner" { bits.append(DS.name(m.runner)) }
        }
        if let t = m.task { bits.append("T\(t)") }
        if let ts = m.ts { bits.append(clock(ts, "h:mm a")) }
        return bits.joined(separator: " · ")
    }
}

struct PlanView: View {
    var text: String
    var steps: [ConvoStep]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if steps.count <= 1, let s = steps.first {
                row(s, single: text)
            } else {
                Text(steps.isEmpty ? text : "Split into \(steps.count) parts").font(SW.a(12, 700)).foregroundStyle(DS.label2)
                ForEach(steps) { s in row(s, single: nil) }
            }
        }
        .padding(.vertical, 2)
    }

    func row(_ s: ConvoStep, single: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(s.status).frame(width: 14)
            Text(DS.code(s.runner)).font(SW.a(10, 800)).tracking(0.6).foregroundStyle(DS.runner(s.runner))
            VStack(alignment: .leading, spacing: 1) {
                Text(single.map { $0.replacingOccurrences(of: "→ ", with: "") } ?? "\(s.idx + 1). \(s.title)\(s.after.isEmpty ? "" : "  (after \(s.after.map { String($0 + 1) }.joined(separator: ", ")))")")
                    .font(SW.a(12.5, 500)).foregroundStyle(DS.label2).lineLimit(2)
                let detail = [s.runner != "local" && !s.model.isEmpty ? s.model + (s.effort.isEmpty ? "" : " · \(s.effort)") : "", s.task.map { "T\($0)" } ?? "", s.status == "working" ? s.progress : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(SW.a(11, 400)).foregroundStyle(DS.label3).lineLimit(1) }
            }
        }
    }

    @ViewBuilder func icon(_ st: String) -> some View {
        switch st {
        case "working": ProgressView().controlSize(.mini)
        case "done": Image(systemName: "checkmark").font(SW.a(11, 700)).foregroundStyle(DS.positive)
        case "failed": Image(systemName: "xmark").font(SW.a(11, 700)).foregroundStyle(DS.critical)
        case "cancelled": Image(systemName: "minus").font(SW.a(11, 700)).foregroundStyle(DS.label3)
        case "queued": Image(systemName: "arrow.right").font(SW.a(11, 700)).foregroundStyle(DS.label2)
        default: Image(systemName: "clock").font(SW.a(11, 500)).foregroundStyle(DS.label3)
        }
    }
}

/// The three (or more) runners, live, so one glance shows who is free while you chat.
struct RunnerStrip: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.snap?.runners ?? []) { r in
                HStack(spacing: 7) {
                    LiveDot(color: DS.runner(r.id), pulse: r.state == "working")
                    Text(r.name).font(SW.a(12.5, 600))
                    Text(r.state.capitalized).font(SW.a(11.5, 400)).foregroundStyle(r.state == "waiting" ? SW.red : DS.label3)
                    Spacer(minLength: 0)
                }
                .help(r.text)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Claude asking before it uses a tool, relayed with Claude's own wording and buttons. Tapping one presses that button in the
/// runner's Claude window; nothing is approved without a tap here (or in Claude itself).
struct PermissionCard: View {
    @EnvironmentObject var store: Store
    var m: ConvoMsg
    @State private var sent: String?
    var answered: String? { m.state.hasPrefix("answered: ") ? String(m.state.dropFirst(10)) : (m.state == "closed" ? "answered in Claude" : sent) }
    static func allows(_ o: String) -> Bool { let l = o.lowercased(); return l.hasPrefix("allow") || l.hasPrefix("always") || ["approve", "accept", "run", "continue", "yes, allow"].contains(l) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(DS.code(m.runner)).font(SW.a(10.5, 800)).tracking(0.6).foregroundStyle(DS.onRunner).padding(.horizontal, 6).padding(.vertical, 2).background(DS.runner(m.runner))
                Text("\(DS.name(m.runner)) needs your permission").font(SW.a(12.5, 700))
                Spacer()
                if let t = m.task { Text("T\(t)").font(SW.a(11, 500)).foregroundStyle(DS.label3) }
            }
            Text(m.text).font(SW.a(14, 400)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let a = answered {
                Label(a.hasPrefix("answered") ? a.capitalized : "You chose \u{201C}\(a)\u{201D}", systemImage: "checkmark.circle").font(SW.a(12.5, 600)).foregroundStyle(DS.label2)
            } else {
                HStack(spacing: 8) {
                    ForEach(m.options ?? [], id: \.self) { o in
                        Button(o) {
                            sent = o
                            store.cli(["convo", "permit", "M\(m.id)", o], quiet: true) { ok, out in if !ok { sent = nil; store.say(out) } }
                        }
                        .buttonStyle(QuietButton(color: Self.allows(o) ? DS.positive : DS.label2))
                    }
                }
            }
        }
        .padding(14)
        .background(DS.raised)
        .overlay(alignment: .leading) { Rectangle().fill(SW.red).frame(width: 3) }
    }
}
