#if os(iOS)
import SwiftUI

/// Ask: a Messages-style thread with a Liquid Glass composer pinned above the keyboard.
struct PhoneAsk: View {
    @EnvironmentObject var s: Store
    @EnvironmentObject var m: AskModel
    @FocusState private var focused: Bool

    let picks: [(String, String, String)] = [
        ("auto", "Auto", "sparkles"),
        ("local", "Mac · Qwen", "desktopcomputer"),
        ("pro", "Pro", "p.circle"),
        ("ultra", "Ultra", "u.circle"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(m.entries) { e in AskTurnP(e: e).id(e.id) }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .overlay {
                if m.entries.isEmpty {
                    ContentUnavailableView("Ask Anything", systemImage: "text.bubble",
                                           description: Text("Or hand off a job. Qwen goes first, Claude only when it has to."))
                }
            }
            .onChange(of: m.entries.count) { _, _ in
                if let l = m.entries.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Ask")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Send to", selection: $m.pick) {
                        ForEach(picks, id: \.0) { p in Label(p.1, systemImage: p.2).tag(p.0) }
                    }
                } label: {
                    Label(m.pick == "auto" ? "Auto" : D.name(m.pick), systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .onAppear(perform: takeFocus)
        .onChange(of: m.wantsFocus) { _, _ in takeFocus() }
    }

    func takeFocus() {
        guard m.wantsFocus else { return }
        m.wantsFocus = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
    }

    var canSend: Bool { !m.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !m.sending }

    var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let q = m.question { QuestionCard(m: m, q: q) }
            if let r = s.replyTarget { ReplyChip(n: r).padding(.horizontal, 6) }
            composerRow
        }
        .onChange(of: s.replyTarget?.id) { _, id in if id != nil { m.question = nil; focused = true } }
    }

    var composerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(s.replyTarget.map { "Your answer to \($0.code)…" } ?? "Ask or hand off…", text: $m.draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
            Button {
                m.submit()
            } label: {
                Group {
                    if m.sending { ProgressView() } else { Image(systemName: "arrow.up").font(.body.weight(.bold)) }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(!canSend)
            .sensoryFeedback(.impact(weight: .light), trigger: m.entries.count)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct AskTurnP: View {
    @EnvironmentObject var s: Store
    @EnvironmentObject var m: AskModel
    var e: AskEntry
    var task: BTask? { e.tid.flatMap { id in s.tasks.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 56)
                Text(e.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(P.accent, in: .rect(cornerRadius: 20, style: .continuous))
                    .textSelection(.enabled)
            }
            if let err = e.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(P.accent).lineLimit(4)
            } else if let r = e.route {
                reply(r)
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Routing…").foregroundStyle(.secondary) }
                    .font(.subheadline)
            }
        }
    }

    func reply(_ r: RouteInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RunnerAvatar(who: r.who, on: true, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.who == "local" ? "Mac · local, no usage" : D.name(r.who)).font(.subheadline.weight(.semibold))
                    if let w = r.why { Text(w).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 4)
                if let t = task {
                    StatusPill(text: t.isDone ? "Answer" : ((t.live ?? false) ? "Working" : "Queued"),
                               color: t.isDone ? .green : P.tint(t.holder ?? t.forWho))
                }
            }
            if let t = task {
                if let o = t.output, let text = s.backend.readOutput(o) {
                    Text(text).lineSpacing(3).textSelection(.enabled)
                } else if let res = t.result, !res.isEmpty {
                    Text(res).textSelection(.enabled)
                } else if let p = t.progress, !p.isEmpty {
                    Text(p).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if r.who == "local", !(task?.isDone ?? false) {
                Button("Send to Ultra instead", systemImage: "arrow.up.right") { m.send(as: "ultra", text: e.text) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.trailing, 32)
    }
}
#endif
