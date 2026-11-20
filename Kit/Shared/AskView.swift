import SwiftUI

struct RouteInfo: Decodable { var who: String?; var dest: String?; var why: String?; var mode: String?; var tid: Int?; var ok: Bool? }

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
    weak var store: Store?
    private var gen = 0

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
        guard !t.isEmpty, !sending, let b = store?.backend else { return }
        sending = true
        let w = who ?? pick
        entries.append(AskEntry(text: t))
        let id = entries.last!.id
        if text == nil { draft = ""; preview = nil }
        store?.tab = .ask
        b.run(["ask", t] + (w == "auto" ? [] : ["--who", w])) { ok, out in
            self.sending = false
            guard let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
            if let r: RouteInfo = lastJSON(out) { self.entries[i].route = r; self.entries[i].tid = r.tid }
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
                .overlay(Rectangle().strokeBorder(D.ink, lineWidth: 2))
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
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                if still { Text("Ask or hand off…").font(D.a(15)).foregroundStyle(D.quiet).frame(maxWidth: .infinity, alignment: .leading) } else {
                TextField("Ask or hand off…", text: $m.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(D.a(15)).foregroundStyle(D.ink)
                    .lineLimit(1...5).focused(focused)
                    .onSubmit { m.send() }
                    .onChange(of: m.draft) { _, _ in m.previewRoute() }
                }
                if m.sending { ProgressView().controlSize(.small) }
                else if !m.draft.isEmpty {
                    Button { m.send() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(D.ink)
                    }.buttonStyle(.plain)
                } else if hint && !still {
                    Text("⌘K").font(D.monoSmall).foregroundStyle(D.quiet)
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(minHeight: 44)
            .overlay(Rectangle().strokeBorder(D.ink, lineWidth: 2))
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
        .padding(.horizontal, 24).padding(.vertical, 10)
    }
}
