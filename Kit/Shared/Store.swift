import Foundation
import SwiftUI

/// Where the board comes from and where actions go. The Mac reads Bridge's live snapshot and runs the
/// `bridge` CLI; the iPhone reads the copy the Mac relay puts in iCloud and drops request files for it.
@MainActor
protocol Backend: AnyObject {
    var name: String { get }                      // shown when the data is stale: "engine", "iCloud"
    func start(_ onSnap: @escaping (Snap) -> Void)
    func age() -> TimeInterval?                   // seconds since the data was written
    /// Runs one allowlisted bridge command as the owner. Calls back with exit success and the command's output.
    func run(_ args: [String], done: @escaping (Bool, String) -> Void)
    func readOutput(_ path: String) -> String?
    func openRunner(_ id: String)
    func open(url: URL)
    var livePreview: Bool { get }                 // can "route" run quickly enough to preview while typing?
}

/// One thing only the owner can act on: a task for him, an open "need", or an action waiting for his approval.
struct NeedItem: Identifiable {
    enum Kind { case task, need, approval }
    var id: String            // T21 · N4 · A7, what the bridge CLI takes
    var kind: Kind
    var code: String          // shown in the ID column
    var title: String
    var detail: String
    var due: String?
    var url: String?
}

@MainActor
public final class Store: ObservableObject {
    @Published var snap = Snap()
    @Published var tab: Tab = .now
    @Published var toast: String?
    /// Mac: the task whose details are open (Open on a task with no link).
    @Published var sheetTask: BTask?
    /// The Needs-you item being answered: the ask bar at the bottom switches to "Replying to …" while this is set.
    @Published var replyTarget: NeedItem?
    @Published var busy: Set<String> = []
    /// Optimistic: what the owner just finished disappears at once; the engine confirms a moment later.
    @Published var settled: Set<String> = []
    @Published var tick = Date()
    /// Set by a Command tile; BoardView opens on this tab (Moving / Open / Mine / Done) and clears it.
    @Published public var boardJump: String?
    let backend: Backend
    private var timer: Timer?

    enum Tab: String, CaseIterable, Hashable { case now = "Now", needs = "Needs", board = "Board", ask = "Ask" }

    init(backend: Backend) {
        self.backend = backend
        backend.start { [weak self] s in
            guard let self else { return }
            self.snap = s
            // A reply target that left Needs (done elsewhere, answered, reassigned) stops being one.
            if let r = self.replyTarget, !self.needs.contains(where: { $0.id == r.id }) { self.replyTarget = nil }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick = Date() } }
    }

    var stale: Bool { (backend.age() ?? 9999) > (backend.name == "engine" ? 15 : 180) }
    var staleText: String {
        guard let a = backend.age() else { return "No data from \(backend.name) yet" }
        let m = Int(a / 60)
        let via = backend.name == "engine" ? "" : " · via \(backend.name)"
        return (m < 1 ? "Updated just now" : "Last update \(m < 90 ? "\(m) min" : "\(m / 60) h") ago") + via
    }

    // MARK: derived
    func runner(_ id: String) -> Runner? { snap.runners?.first { $0.id == id } }
    var tasks: [BTask] { snap.tasks ?? [] }

    var needs: [NeedItem] {
        var out: [NeedItem] = []
        for a in snap.actions ?? [] where a.status == "approval" {
            out.append(NeedItem(id: "A\(a.id)", kind: .approval, code: "A\(a.id)", title: a.summary ?? (a.kind ?? "Action"), detail: kindName(a.kind), due: nil, url: nil))
        }
        for n in snap.attention ?? [] {
            out.append(NeedItem(id: "N\(n.id)", kind: .need, code: n.task.map { "T\($0)" } ?? "N\(n.id)", title: n.title, detail: n.detail ?? (n.kind ?? ""), due: n.due, url: n.url))
        }
        for t in tasks where !t.isDone && t.forWho == "naren" {
            out.append(NeedItem(id: "T\(t.id)", kind: .task, code: "T\(t.id)", title: clean(t.title), detail: t.progress ?? "", due: t.due, url: nil))
        }
        return out.filter { !settled.contains($0.id) }
    }
    var needCount: Int { needs.count }
    var approvals: [NeedItem] { needs.filter { $0.kind == .approval } }

    private func kindName(_ k: String?) -> String {
        switch k ?? "" {
        case "message.send": return "Message"
        case "vault.fill": return "Login fill"
        case "event.add", "event.remove": return "Calendar"
        case "reminder.add": return "Reminder"
        default: return "Action"
        }
    }

    // MARK: actions (everything goes through the bridge CLI, acting as the owner)
    func complete(_ n: NeedItem) {
        switch n.kind {
        case .task: act(["done", n.id, "Done by the owner in Bridge"], key: n.id, ok: "\(n.id) done")
        case .need: act(["resolve", n.id, "done"], key: n.id, ok: "Cleared")
        case .approval: act(["approve", n.id], key: n.id, ok: "Approved")
        }
    }
    /// the owner's answer: a decision item takes it directly; a task goes back to a runner with the answer in it.
    func reply(_ id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if id.hasPrefix("N") { act(["resolve", id, t], key: id, ok: "Answered") }
        else { act(["reply", id, t], key: id, ok: "\(id) sent to Claude with your answer") }
    }
    func deny(_ n: NeedItem) { act(["deny", n.id], key: n.id, ok: "Denied") }
    func open(_ n: NeedItem) {
        if let u = n.url, let url = URL(string: u) { backend.open(url: url); return }
        #if os(macOS)
        if let t = tasks.first(where: { "T\($0.id)" == n.id || (n.code == "T\($0.id)") }) { sheetTask = t; return }
        #endif
        tab = .board
    }

    func act(_ args: [String], key: String, ok: String) {
        let settles = ["done", "resolve", "approve", "deny", "reply"].contains(args.first ?? "")
        if settles { withAnimation(.easeOut(duration: 0.2)) { _ = settled.insert(key) }; say(ok) } else { busy.insert(key) }
        backend.run(args) { success, out in
            self.busy.remove(key)
            let last = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
            // Already closed elsewhere (phone, a runner, the CLI) is the outcome the owner asked for, not an error.
            let already = last.hasPrefix("ALREADY DONE")
            let good = (success && !last.hasPrefix("ERROR")) || already
            if !good { withAnimation { _ = self.settled.remove(key) }; self.say(last.isEmpty ? "Didn't go through" : last, long: true) }
            else if !settles { self.say(ok) }
        }
    }
    func say(_ s: String, long: Bool = false) {
        withAnimation(.easeOut(duration: 0.18)) { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + (long ? 8 : 2.4)) { if self.toast == s { withAnimation(.easeOut(duration: 0.18)) { self.toast = nil } } }
    }
}

func clean(_ t: String) -> String { t.replacingOccurrences(of: "[Grok] ", with: "") }

private let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
func dueDays(_ d: String?) -> Int {
    guard let d, d.count == 10, let date = dayFmt.date(from: d) else { return 999 }
    return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day ?? 999
}
func dueText(_ d: String?) -> String {
    guard let d, d.count == 10, let date = dayFmt.date(from: d) else { return "" }
    let days = dueDays(d)
    if days == 0 { return "Today" }
    if days == 1 { return "Tomorrow" }
    if days < 0 { return "\(-days)d late" }
    let f = DateFormatter()
    f.dateFormat = days < 7 ? "EEE" : "MMM d"
    return f.string(from: date)
}
func elapsed(_ s: Double) -> String {
    let v = max(0, Int(s))
    return v >= 3600 ? String(format: "%d:%02d:%02d", v / 3600, v / 60 % 60, v % 60) : String(format: "%d:%02d", v / 60, v % 60)
}
