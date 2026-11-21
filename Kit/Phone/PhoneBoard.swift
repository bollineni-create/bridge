#if os(iOS)
import SwiftUI

/// Board: segmented filter, search, swipe to finish or hand to the Mac, push into a task.
struct PhoneBoard: View {
    @EnvironmentObject var s: Store
    @EnvironmentObject var link: PhoneLink
    @State private var seg = "Moving"
    @State private var query = ""
    let segs = ["Moving", "Open", "Mine", "Done"]

    var rows: [BTask] {
        let t = s.tasks.map { x -> BTask in var y = x; if s.settled.contains("T\(x.id)") { y.status = "done" }; return y }
        var list: [BTask]
        switch seg {
        case "Moving": list = t.filter { !$0.isDone && ($0.live ?? false) }
        case "Open": list = t.filter { !$0.isDone && !["naren", "parked"].contains($0.forWho ?? "") }.sorted { dueDays($0.due) < dueDays($1.due) }
        case "Mine": list = t.filter { !$0.isDone && $0.forWho == "naren" }.sorted { dueDays($0.due) < dueDays($1.due) }
        default: list = Array(t.filter { $0.isDone }.sorted { ($0.doneTs ?? 0) > ($1.doneTs ?? 0) }.prefix(40))
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(q) || "T\($0.id)".localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let list = rows
        List {
            Section {
                ForEach(list) { t in
                    NavigationLink(value: t) { BoardRowP(t: t, showResult: seg == "Done") }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if !t.isDone {
                                Button { done(t) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if !t.isDone && t.forWho != "local" {
                                Button { toMac(t) } label: { Label("To Mac", systemImage: "desktopcomputer") }.tint(D.mac)
                            }
                        }
                }
            } header: {
                Picker("Show", selection: $seg) {
                    ForEach(segs, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if list.isEmpty {
                if !query.isEmpty { ContentUnavailableView.search(text: query) }
                else if seg == "Moving" {
                    ContentUnavailableView("Nothing Is Moving", systemImage: "pause.circle",
                                           description: Text("Open tasks start when a runner checks in."))
                } else {
                    ContentUnavailableView("Empty", systemImage: "tray")
                }
            }
        }
        .animation(.default, value: list.map(\.id))
        .navigationTitle("Board")
        .navigationDestination(for: BTask.self) { TaskDetail(id: $0.id, fallback: $0) }
        .searchable(text: $query, prompt: "Search tasks")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ComposeButton() } }
        .refreshable { await link.pull() }
    }

    func done(_ t: BTask) { s.act(["done", "T\(t.id)", "Done in Bridge"], key: "T\(t.id)", ok: "T\(t.id) done") }
    func toMac(_ t: BTask) { s.act(["assign", "T\(t.id)", "local"], key: "T\(t.id)", ok: "T\(t.id) → Mac") }
}

struct BoardRowP: View {
    var t: BTask
    var showResult = false
    var body: some View {
        HStack(spacing: 12) {
            RunnerAvatar(who: t.holder ?? t.forWho, on: t.live ?? false, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(clean(t.title))
                    .font(.body)
                    .foregroundStyle(t.isDone ? .secondary : .primary)
                    .lineLimit(2)
                if showResult, let r = t.result, !r.isEmpty {
                    Text(r).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                } else if (t.live ?? false), let p = t.progress, !p.isEmpty {
                    Text(p).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("T\(t.id)").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Text(t.isDone ? "Done" : dueText(t.due))
                .font(.subheadline)
                .foregroundStyle((t.overdue ?? false) ? P.accent : .secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Task detail, pushed onto the Board stack. Reads live from the store so it updates while open.
struct TaskDetail: View {
    @EnvironmentObject var s: Store
    @Environment(\.dismiss) private var dismiss
    let id: Int
    let fallback: BTask
    var t: BTask { s.tasks.first { $0.id == id } ?? fallback }
    var status: String { t.isDone ? "Done" : ((t.live ?? false) ? "Moving" : "Open") }

    var body: some View {
        let t = self.t
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(clean(t.title))
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        RunnerAvatar(who: t.holder ?? t.forWho, on: t.live ?? false, size: 28)
                        Text(D.name(t.holder ?? t.forWho)).font(.subheadline.weight(.semibold))
                        Spacer()
                        StatusPill(text: status, color: t.isDone ? .green : ((t.live ?? false) ? P.tint(t.holder) : .secondary))
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Details") {
                LabeledContent("Task", value: "T\(t.id)")
                LabeledContent("For", value: D.name(t.forWho))
                if !dueText(t.due).isEmpty {
                    LabeledContent("Due") {
                        Text(dueText(t.due)).foregroundStyle((t.overdue ?? false) ? P.accent : .secondary)
                    }
                }
            }
            if let r = t.result, !r.isEmpty {
                Section("Result") { Text(r).textSelection(.enabled) }
            }
            if let o = t.output, let text = s.backend.readOutput(o) {
                Section("Output") { Text(text).font(.callout).textSelection(.enabled) }
            } else if let p = t.progress, !p.isEmpty {
                Section("Progress") { Text(p) }
            }
            if !t.isDone && t.forWho != "local" {
                Section {
                    Button("Hand to Mac (Qwen)", systemImage: "desktopcomputer") {
                        s.act(["assign", "T\(t.id)", "local"], key: "T\(t.id)", ok: "T\(t.id) → Mac")
                    }
                } footer: {
                    Text("Runs locally on your Mac. No Claude usage.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("T\(t.id)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !t.isDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark Done", systemImage: "checkmark") {
                        s.act(["done", "T\(t.id)", "Done in Bridge"], key: "T\(t.id)", ok: "T\(t.id) done")
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
