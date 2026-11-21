import SwiftUI

struct RouteInfo: Decodable { var who: String?; var dest: String?; var why: String?; var mode: String?; var tid: Int?; var ok: Bool? }

/// A routing question Bridge asks before sending (account, chat, project), like Claude's own multiple-choice questions.
struct ClarOpt: Decodable, Hashable { var label: String; var value: String; var desc: String? }
struct ClarQ: Decodable, Equatable {
    var key: String
    var question: String
    var options: [ClarOpt]
    var `default`: String?
}
struct ClarResp: Decodable { var questions: [ClarQ]? }

struct AskEntry: Identifiable {
    let id = UUID()
    var text: String
    var route: RouteInfo?
    var tid: Int?
    var error: String?
}

@MainActor
final class AskModel: ObservableObject {
    @Published var draft = ""
    @Published var pick = "auto"          // auto | local | pro | ultra
    @Published var preview: RouteInfo?
    @Published var entries: [AskEntry] = []
    @Published var sending = false
    @Published var wantsFocus = false
    /// The question Bridge is asking about the request in `pending` before it routes it.
    @Published var question: ClarQ?
    @Published var pending: String?
    private var answers: [String: String] = [:]
    weak var store: Store?
    private var gen = 0
    /// One box, one conversation, for every Mac window.
    static let shared = AskModel()

    /// Return / the arrow in the box: an answer when replying to a Needs-you item, otherwise a new request.
    func submit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let s = store else { return }
        if let r = s.replyTarget {
            s.reply(r.id, t)
            s.replyTarget = nil
            draft = ""
            return
        }
        send()
    }

    /// The answers so far, as `bridge ask/clarify` flags.
    private func flags() -> [String] {
        var f: [String] = []
        var who = answers["who"], whereV: String?, chat: String?
        if let th = answers["thread"] {
            if th == "new" { whereV = "new" }
            else if th.hasPrefix("chat:") {
                let rest = th.dropFirst(5)
                if let i = rest.firstIndex(of: ":") { if who == nil { who = String(rest[..<i]) }; chat = String(rest[rest.index(after: i)...]) }
            }
        }
        if let w = who { f += ["--who", w] }
        if let p = answers["project"] { whereV = p == "none" ? "new" : "project"; f += ["--project", p] }
        if let w = whereV { f += ["--where", w] }
        if let c = chat { f += ["--chat", c] }
        return f
    }

    /// Ask Bridge what it is unsure about; show the first question, or send when nothing is unclear.
    private func askNext() {
        guard let t = pending, let b = store?.backend else { return }
        sending = true
        b.run(["clarify", t] + flags()) { _, out in
            self.sending = false
            guard self.pending == t else { return }
            if let r: ClarResp = lastJSON(out), let q = r.questions?.first { self.question = q }
            else { self.dispatch(t) }       // nothing unclear (or an older engine without clarify): just send
        }
    }

    func answer(_ value: String) {
        guard let q = question else { return }
        answers[q.key] = value
        question = nil
        askNext()
    }
    /// "Let Bridge decide": send with what is answered so far.
    func skip() { question = nil; if let t = pending { dispatch(t) } }
    /// Back out: the text returns to the box.
    func cancelQuestion() { question = nil; if let t = pending, draft.isEmpty { draft = t }; pending = nil; answers = [:] }

    func previewRoute() {
        guard let b = store?.backend, b.livePreview else { return }
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        gen += 1; let g = gen
        guard t.count > 3 else { preview = nil; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard g == self.gen else { return }
            b.run(["route", t] + (self.pick == "auto" ? [] : ["--who", self.pick])) { _, out in
                guard g == self.gen else { return }
                self.preview = lastJSON(out)
            }
        }
    }

    func send(as who: String? = nil, text: String? = nil) {
        let t = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending, question == nil, store?.backend != nil else { return }
        if text == nil { draft = ""; preview = nil }
        answers = [:]
        let w = who ?? pick
        if w != "auto" { answers["who"] = w }
        pending = t
        if who != nil { dispatch(t) } else { askNext() }    // an explicit "Send to Ultra" needs no questions
    }

    private func dispatch(_ t: String) {
        guard let b = store?.backend else { return }
        pending = nil
        sending = true
        entries.append(AskEntry(text: t))
        let id = entries.last!.id
        store?.tab = .ask
        b.run(["ask", t] + flags()) { ok, out in
            self.sending = false
            self.answers = [:]
            guard let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
            if let r: RouteInfo = lastJSON(out) {
                self.entries[i].route = r; self.entries[i].tid = r.tid
                self.store?.say("Sent to \(D.name(r.who)) · \(r.dest ?? "")")
            }
            else { self.entries[i].error = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bridge didn't answer" : out }
        }
    }
}

func lastJSON<T: Decodable>(_ out: String) -> T? {
    guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }) else { return nil }
    return try? JSONDecoder().decode(T.self, from: Data(line.utf8))
}

struct AskView: View {
    @EnvironmentObject var s: Store
    @ObservedObject var m: AskModel
    var showTitle = true
    var body: some View {
        ScrollViewReader { proxy in
            Scroller {
                VStack(alignment: .leading, spacing: 20) {
                    if showTitle { PageTitle(title: "Ask", sub: "Qwen goes first. Claude only when it has to.") }
                    if m.entries.isEmpty {
                        EmptyNote(text: "Ask anything, or hand off a job.", sub: "Bridge picks the runner and shows you why.")
                    }
                    ForEach(m.entries) { e in AskTurn(e: e, m: m).id(e.id) }
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
            }
            .onChange(of: m.entries.count) { _, _ in if let l = m.entries.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
        }
    }
}

struct AskTurn: View {
    @EnvironmentObject var s: Store
    var e: AskEntry
    @ObservedObject var m: AskModel
    var task: BTask? { e.tid.flatMap { id in s.tasks.first { $0.id == id } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Spacer(minLength: 48)
                Text(e.text).font(D.a(15)).foregroundStyle(D.ink).textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12).background(D.wash)
            }
            if let err = e.error {
                Text(err).font(D.a(13)).foregroundStyle(D.red).lineLimit(4)
            } else if let r = e.route {
                HStack(spacing: 12) {
                    Badge(who: r.who, filled: true, big: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.who == "local" ? "Routed to Mac · local, no usage" : "Routed to \(D.name(r.who))").font(D.a(14, 700)).foregroundStyle(D.ink)
                        if let w = r.why { Text(w).font(D.a(12.5)).foregroundStyle(D.quiet).lineLimit(2) }
                    }
                    Spacer(minLength: 4)
                    if r.who == "local", !(task?.isDone ?? false) {
                        Button("Send to Ultra") { m.send(as: "ultra", text: e.text) }.buttonStyle(SquareButton())
                    }
                }
                .padding(12)
                .overlay(Rectangle().strokeBorder(D.line, lineWidth: 2))
                answer
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Routing…").font(D.a(13)).foregroundStyle(D.quiet) }
            }
        }
    }

    @ViewBuilder var answer: some View {
        if let t = task {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Badge(who: t.holder ?? t.forWho, filled: !t.isDone)
                    Text(t.isDone ? "Answer" : ((t.live ?? false) ? "Working" : "Queued")).font(D.a(13, 600)).foregroundStyle(D.ink)
                    Spacer()
                    Text("T\(t.id)").font(D.monoSmall).foregroundStyle(D.quiet)
                }
                if let o = t.output, let text = s.backend.readOutput(o) {
                    Text(text).font(D.a(15)).foregroundStyle(D.body).lineSpacing(4).textSelection(.enabled)
                } else if let r = t.result, !r.isEmpty {
                    Text(r).font(D.a(15)).foregroundStyle(D.body).textSelection(.enabled)
                } else if let p = t.progress, !p.isEmpty {
                    Text(p).font(D.a(13)).foregroundStyle(D.quiet)
                }
                if let r = t.result, r.uppercased().contains("HANDOFF") {
                    Rule()
                    Text(r).font(D.monoSmall).foregroundStyle(D.quiet).lineLimit(3)
                }
            }
        }
    }
}

/// The ask bar at the bottom of every screen: square, 2px black, with the route chip.
struct AskBar: View {
    @EnvironmentObject var s: Store
    @ObservedObject var m: AskModel
    var focused: FocusState<Bool>.Binding
    let picks = [("auto", "Auto"), ("local", "Mac"), ("pro", "Pro"), ("ultra", "Ultra")]
    @Environment(\.still) private var still
    #if os(macOS)
    let hint = true
    #else
    let hint = false
    #endif
    var chip: (String, Color) {
        if m.pick != "auto" { return (D.name(m.pick), D.color(m.pick)) }
        if let w = m.preview?.who { return ("Auto → " + D.name(w), D.color(w)) }
        return ("Auto", D.quiet)
    }
    var placeholder: String { s.replyTarget.map { "Your answer to \($0.code)…" } ?? "Ask or hand off…" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let q = m.question { QuestionCard(m: m, q: q) }
            if let r = s.replyTarget { ReplyChip(n: r) }
            bar
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .onChange(of: s.replyTarget?.id) { _, id in if id != nil { m.question = nil; focused.wrappedValue = true } }
        #if os(macOS)
        .onExitCommand { if s.replyTarget != nil { s.replyTarget = nil } else if m.question != nil { m.cancelQuestion() } }
        #endif
    }
    var bar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                if still { Text("Ask or hand off…").font(D.a(15)).foregroundStyle(D.quiet).frame(maxWidth: .infinity, alignment: .leading) } else {
                TextField(placeholder, text: $m.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(D.a(15)).foregroundStyle(D.ink)
                    .lineLimit(1...5).focused(focused)
                    .onSubmit { m.submit() }
                    .onChange(of: m.draft) { _, _ in if s.replyTarget == nil { m.previewRoute() } }
                }
                if m.sending { ProgressView().controlSize(.small) }
                else if !m.draft.isEmpty {
                    Button { m.submit() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(D.onInk)
                            .frame(width: 28, height: 28).background(D.solid)
                    }.buttonStyle(.plain)
                } else if hint && !still {
                    Text("⌘K").font(D.monoSmall).foregroundStyle(D.quiet)
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(minHeight: 44)
            .overlay(Rectangle().strokeBorder(s.replyTarget == nil ? D.line : D.red, lineWidth: 2))
            if s.replyTarget == nil {
            Menu {
                ForEach(picks, id: \.0) { p in Button(p.1) { m.pick = p.0; m.previewRoute() } }
            } label: {
                Text(chip.0).font(D.a(12.5, 600)).foregroundStyle(chip.1 == D.quiet ? D.quiet : D.ink)
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .overlay(Rectangle().strokeBorder(chip.1, lineWidth: 1))
                    .overlay(alignment: .leading) { Rectangle().fill(chip.1).frame(width: 4) }
            }
            #if os(macOS)
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            #endif
            .fixedSize()
            }
        }
    }
}

/// "Replying to T24 · Starlink …" above the box, with a way out.
struct ReplyChip: View {
    @EnvironmentObject var s: Store
    var n: NeedItem
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(D.red).frame(width: 4, height: 18)
            Text("Replying to \(n.code)").font(D.a(12.5, 700)).foregroundStyle(D.ink)
            Text(n.title).font(D.a(12.5)).foregroundStyle(D.quiet).lineLimit(1)
            Spacer(minLength: 4)
            Button { s.replyTarget = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(D.quiet) }
                .buttonStyle(.plain).help("Cancel reply (Esc)")
        }
    }
}

/// Bridge's routing question, Claude-style: the question, numbered choices with a line each, a suggested one, and a way to let Bridge decide.
struct QuestionCard: View {
    @ObservedObject var m: AskModel
    var q: ClarQ
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(q.question).font(D.a(14.5, 700)).foregroundStyle(D.ink)
                Spacer(minLength: 4)
                Button("Let Bridge decide") { m.skip() }.buttonStyle(SquareButton(quiet: true)).fixedSize()
                Button { m.cancelQuestion() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(D.quiet) }
                    .buttonStyle(.plain).help("Cancel")
            }
            if let p = m.pending { Text("\u{201C}\(p)\u{201D}").font(D.a(12.5)).foregroundStyle(D.quiet).lineLimit(1) }
            if q.options.count > 4 { ScrollView { choices }.frame(height: 230) } else { choices }
        }
        .padding(12).background(D.paper)
        .overlay(Rectangle().strokeBorder(D.line, lineWidth: 2))
    }
    var choices: some View {
        VStack(spacing: 4) {
            ForEach(Array(q.options.enumerated()), id: \.element) { i, o in
                Button { m.answer(o.value) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(D.monoSmall).foregroundStyle(D.quiet).frame(width: 16, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.label).font(D.a(14, 600)).foregroundStyle(D.ink).lineLimit(2)
                            if let d = o.desc, !d.isEmpty { Text(d).font(D.a(12)).foregroundStyle(D.quiet).lineLimit(2) }
                        }
                        Spacer(minLength: 4)
                        if o.value == q.default { Text("Suggested").font(D.a(11, 600)).foregroundStyle(D.quiet) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .overlay(Rectangle().strokeBorder(o.value == q.default ? D.line : D.quiet.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
