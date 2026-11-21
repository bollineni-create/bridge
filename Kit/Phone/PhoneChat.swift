#if os(iOS)
import SwiftUI
import UIKit

// Bridge Chat on the iPhone: the same conversations as the Mac app (engine bridge_convo.py). One box for every runner:
// Bridge routes or splits each message, you can pick the runner, the Claude model and the effort, and every answer comes back here.

private func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// What the composer sends with: shared by the list (new chat) and each conversation.
final class ChatPrefs: ObservableObject {
    @Published var who = "auto"
    @Published var model = ""
    @Published var effort = ""
}

struct PhoneChatList: View {
    @EnvironmentObject var s: Store
    @StateObject private var prefs = ChatPrefs()
    @State private var path: [Int] = []
    @State private var newChat = false

    var convos: [PConvo] { s.snap.convos ?? [] }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ChatRunnerRow()
                }
                Section("Chats") {
                    if convos.isEmpty {
                        Text("No chats yet. Tap the pencil to start one.").foregroundStyle(.secondary)
                    }
                    ForEach(convos) { c in
                        NavigationLink(value: c.id) { ConvoRow(c: c) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { s.act(["convo", "delete", "C\(c.id)"], key: "C\(c.id)", ok: "Deleted") }
                                if c.status == "working" { Button("Stop") { s.act(["convo", "stop", "C\(c.id)"], key: "C\(c.id)", ok: "Stopped") }.tint(.orange) }
                            }
                    }
                }
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newChat = true } label: { Label("New chat", systemImage: "square.and.pencil") }
                }
            }
            .navigationDestination(for: Int.self) { id in PhoneConvo(convoID: id, prefs: prefs) }
            .navigationDestination(isPresented: $newChat) { PhoneConvo(convoID: nil, prefs: prefs, onCreated: { id in newChat = false; path = [id] }) }
            .refreshable { try? await Task.sleep(for: .milliseconds(600)) }
        }
    }
}

/// The runners, live, so one glance shows who is free.
struct ChatRunnerRow: View {
    @EnvironmentObject var s: Store
    var body: some View {
        HStack(spacing: 14) {
            ForEach(s.snap.runners ?? []) { r in
                HStack(spacing: 6) {
                    RunnerAvatar(who: r.id, on: r.state == "working", size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(D.name(r.id)).font(.caption.weight(.semibold))
                        Text((r.state ?? "").capitalized).font(.caption2).foregroundStyle(r.state == "waiting" ? P.accent : .secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ConvoRow: View {
    var c: PConvo
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if c.status == "working" { ProgressView().controlSize(.small) }
                else if c.status == "waiting" { Circle().fill(P.accent).frame(width: 9, height: 9) }
                else { RunnerAvatar(who: c.runner, on: false, size: 26) }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.body.weight(.medium)).lineLimit(1)
                Text(sub).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    var sub: String {
        let who = (c.runner ?? "").isEmpty ? "" : D.name(c.runner)
        switch c.status ?? "" {
        case "working": return "Working" + (who.isEmpty ? "" : " · \(who)")
        case "waiting": return "\(who.isEmpty ? "A runner" : who) is asking you"
        default:
            let last = c.msgs?.last(where: { $0.role != "user" && $0.kind != "plan" })?.text ?? ""
            return last.isEmpty ? who : last.replacingOccurrences(of: "\n", with: " ")
        }
    }
}

struct PhoneConvo: View {
    @EnvironmentObject var s: Store
    var convoID: Int?
    @ObservedObject var prefs: ChatPrefs
    var onCreated: ((Int) -> Void)? = nil
    @State private var draft = ""
    @State private var pending: [String] = []
    @State private var sending = false
    @FocusState private var focused: Bool

    var c: PConvo? { s.snap.convos?.first { $0.id == convoID } }
    var options: PConvoOptions? { s.snap.convo_options }
    var modelApplies: Bool {
        if prefs.who == "auto" || prefs.who == "split" { return true }
        return (options?.runners ?? []).first { $0.id == prefs.who }?.kind != "local-model"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let c {
                        ForEach(c.msgs ?? []) { m in PMsgView(m: m, steps: (c.steps ?? []).filter { $0.turn == m.turn }).id(m.id) }
                    } else if pending.isEmpty {
                        ContentUnavailableView("One chat for every runner", systemImage: "bubble.left.and.text.bubble.right",
                                               description: Text("Bridge sends it to Qwen, Pro or Ultra, splits it when the parts are separate, and brings every answer back here."))
                            .padding(.top, 60)
                    }
                    ForEach(pending, id: \.self) { p in PMsgView(m: PMsg(id: -1, role: "user", text: p, state: "sending"), steps: []) }
                    if let c, c.status == "working", c.msgs?.last?.role == "user" || c.msgs?.last?.kind == "plan" {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(working(c)).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: c?.msgs?.last?.id) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: pending.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(c?.title ?? "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if c?.status == "working" {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { if let c { s.act(["convo", "stop", "C\(c.id)"], key: "C\(c.id)", ok: "Stopped") } } label: { Label("Stop", systemImage: "stop.fill") }
                }
            }
        }
        .onAppear { if convoID == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } } }
        .onChange(of: c?.msgs?.count) { _, _ in
            if let c { pending.removeAll { p in (c.msgs ?? []).contains { $0.role == "user" && $0.text == p } } }
        }
    }

    func working(_ c: PConvo) -> String {
        let live = (c.steps ?? []).filter { ["pending", "queued", "working"].contains($0.status ?? "") }
        if live.isEmpty { return "Bridge is working out who should take this…" }
        return live.map { "\(D.name($0.runner)) \($0.status == "working" ? "is on it" : "has it queued")" }.joined(separator: " · ")
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Runner", selection: $prefs.who) {
                            Label("Auto · Bridge decides", systemImage: "sparkles").tag("auto")
                            Label("Split across runners", systemImage: "arrow.triangle.branch").tag("split")
                            ForEach(options?.runners ?? []) { r in Text(r.name + (r.kind == "local-model" ? " · free" : "")).tag(r.id) }
                        }
                    } label: { chip(icon: "arrow.triangle.branch", text: whoLabel) }
                    if modelApplies {
                        Menu {
                            Picker("Model", selection: $prefs.model) {
                                Text("Auto · Bridge picks").tag("")
                                ForEach(options?.models ?? ["Haiku 5.5", "Sonnet 5.5", "Opus 5.5"], id: \.self) { Text($0).tag($0) }
                            }
                        } label: { chip(icon: "cpu", text: prefs.model.isEmpty ? "Auto model" : prefs.model) }
                        Menu {
                            Picker("Effort", selection: $prefs.effort) {
                                Text("Auto · Bridge picks").tag("")
                                ForEach(options?.efforts ?? ["low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                            }
                        } label: { chip(icon: "gauge.with.dots.needle.50percent", text: prefs.effort.isEmpty ? "Auto effort" : prefs.effort.capitalized) }
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(c == nil ? "Message all your runners" : "Reply", text: $draft, axis: .vertical)
                    .lineLimit(1...6).focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                Button(action: send) {
                    Image(systemName: sending ? "hourglass" : "arrow.up").font(.body.weight(.bold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.white)
                        .background(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : P.accent, in: .circle)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .padding(.trailing, 6).padding(.bottom, 5)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            if let c, let r = c.runner, !r.isEmpty, prefs.who == "auto" {
                Text((c.chat ?? "").isEmpty ? "Replies go to \(D.name(r)) with this chat's context." : "Replies continue in \(D.name(r))'s chat “\(c.chat!)”.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
        .padding(.horizontal).padding(.bottom, 8).padding(.top, 4)
    }

    var whoLabel: String {
        switch prefs.who {
        case "auto": return "Auto"
        case "split": return "Split"
        default: return options?.runners?.first { $0.id == prefs.who }?.name ?? D.name(prefs.who)
        }
    }

    func chip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon).font(.footnote.weight(.semibold)).labelStyle(.titleAndIcon)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
    }

    func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        var args = ["convo", "send", convoID.map { "C\($0)" } ?? "new", t, "--who", prefs.who]
        if modelApplies && !prefs.model.isEmpty { args += ["--model", prefs.model] }
        if modelApplies && !prefs.effort.isEmpty { args += ["--effort", prefs.effort] }
        draft = ""
        pending.append(t)
        sending = true
        s.backend.run(args) { ok, out in
            sending = false
            let last = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
            guard ok, let d = last.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = j["convo"] as? Int else {
                pending.removeAll { $0 == t }; draft = t; s.say(last.isEmpty ? "Didn't go through" : last, long: true); return
            }
            if convoID == nil { onCreated?(id) }
        }
    }
}

struct PMsgView: View {
    @EnvironmentObject var s: Store
    var m: PMsg
    var steps: [PStep]
    @State private var expanded = false

    var body: some View {
        switch m.role {
        case "user":
            HStack {
                Spacer(minLength: 60)
                Text(md(m.text ?? "")).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(P.accent.opacity(m.state == "sending" ? 0.55 : 1), in: .rect(cornerRadius: 18, style: .continuous))
            }
        case "bridge" where m.kind == "plan":
            VStack(alignment: .leading, spacing: 6) {
                if steps.count > 1 { Text("Split into \(steps.count) parts").font(.caption.weight(.bold)).foregroundStyle(.secondary) }
                ForEach(steps) { st in stepRow(st, single: steps.count <= 1 ? m.text : nil) }
                if steps.isEmpty { Text(m.text ?? "").font(.footnote).foregroundStyle(.secondary) }
            }
        case "bridge" where m.kind == "status":
            Text(m.text ?? "").font(.caption).foregroundStyle(.secondary)
        case "runner" where m.kind == "permission":
            permissionCard
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if m.role == "bridge" {
                        StatusPill(text: m.kind == "summary" ? "Report" : "Bridge", color: .secondary)
                    } else {
                        RunnerAvatar(who: m.runner, on: true, size: 22)
                        Text(D.name(m.runner)).font(.footnote.weight(.semibold))
                    }
                    if m.kind == "question" { StatusPill(text: "Asking you", color: P.accent) }
                    if let t = m.task { Text("T\(t)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
                    Spacer()
                }
                Text(md(shown)).textSelection(.enabled).foregroundStyle(m.kind == "error" ? Color.red : Color.primary)
                if long { Button(expanded ? "Show less" : "Show all") { expanded.toggle() }.font(.footnote.weight(.semibold)) }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .leading) {
                if m.kind == "question" { RoundedRectangle(cornerRadius: 2).fill(P.accent).frame(width: 3).padding(.vertical, 10) }
            }
            .contextMenu { Button { UIPasteboard.general.string = m.text } label: { Label("Copy", systemImage: "doc.on.doc") } }
        }
    }

    @State private var chosen: String?
    var answered: String? {
        let st = m.state ?? ""
        return st.hasPrefix("answered: ") ? "You chose \u{201C}\(st.dropFirst(10))\u{201D}" : (st == "closed" ? "Answered in Claude" : chosen.map { "You chose \u{201C}\($0)\u{201D}" })
    }
    func allows(_ o: String) -> Bool { let l = o.lowercased(); return l.hasPrefix("allow") || l.hasPrefix("always") || ["approve", "accept", "run", "continue", "yes, allow"].contains(l) }

    var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                RunnerAvatar(who: m.runner, on: true, size: 22)
                Text("\(D.name(m.runner)) needs your permission").font(.footnote.weight(.semibold))
                Spacer()
            }
            Text(m.text ?? "").font(.callout)
            if let a = answered {
                Label(a, systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                ViewThatFits {
                    HStack(spacing: 8) { buttons }
                    VStack(alignment: .leading, spacing: 8) { buttons }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(P.accent.opacity(0.6), lineWidth: 1))
    }

    @ViewBuilder var buttons: some View {
        ForEach(m.options ?? [], id: \.self) { o in
            Button(o) {
                chosen = o
                s.backend.run(["convo", "permit", "M\(m.id)", o]) { ok, out in
                    if !ok || out.contains("ERROR") { chosen = nil; s.say(out.components(separatedBy: "\n").last ?? "Didn't go through", long: true) }
                }
            }
            .buttonStyle(.glassProminent).tint(allows(o) ? .green : .gray)
        }
    }

    var long: Bool { (m.text ?? "").count > 1800 }
    var shown: String { long && !expanded ? String((m.text ?? "").prefix(1800)) + "…" : (m.text ?? "") }

    func stepRow(_ st: PStep, single: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch st.status ?? "" {
                case "working": ProgressView().controlSize(.mini)
                case "done": Image(systemName: "checkmark").foregroundStyle(.green)
                case "failed": Image(systemName: "xmark").foregroundStyle(.red)
                case "cancelled": Image(systemName: "minus").foregroundStyle(.secondary)
                case "queued": Image(systemName: "arrow.right").foregroundStyle(.secondary)
                default: Image(systemName: "clock").foregroundStyle(.tertiary)
                }
            }
            .font(.caption.weight(.bold)).frame(width: 14)
            Text(D.code(st.runner)).font(.caption2.weight(.heavy)).foregroundStyle(P.tint(st.runner))
            VStack(alignment: .leading, spacing: 1) {
                Text(single.map { $0.replacingOccurrences(of: "→ ", with: "") } ?? "\(st.idx + 1). \(st.title)").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                let detail = [st.runner != "local" ? [st.model ?? "", st.effort ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") : "",
                              st.task.map { "T\($0)" } ?? "", st.status == "working" ? (st.progress ?? "") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
    }
}

extension PMsg {
    init(id: Int, role: String, text: String, state: String) {
        self.id = id; self.role = role; self.text = text; self.state = state
    }
}
#endif
