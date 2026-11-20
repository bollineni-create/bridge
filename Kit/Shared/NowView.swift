import SwiftUI

/// Now: the three runners as ruled lanes, then the day in tombstones.
struct NowView: View {
    @EnvironmentObject var s: Store
    var showHeader = true
    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 0) {
                if showHeader {
                    HStack(alignment: .center) {
                        Wordmark(size: 30)
                        Spacer()
                        if s.needCount > 0 { Button { s.tab = .needs } label: { RedCount(n: s.needCount, words: true) }.buttonStyle(.plain) }
                        else { Text("All clear").font(D.a(13, 600)).foregroundStyle(D.quiet) }
                    }
                    .padding(.bottom, 18)
                }
                Rule(heavy: true)
                ForEach(["ultra", "pro", "local"], id: \.self) { id in
                    Lane(id: id, r: s.runner(id))
                    Rule()
                }
                stones.padding(.top, 22)
                if s.stale {
                    Text(s.staleText + " · " + s.backend.name).font(D.a(12.5, 600)).foregroundStyle(D.red).padding(.top, 10)
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
        }
    }

    var stones: some View {
        let c = s.snap.counts
        return Tombstones(stones: [
            .init(figure: "\(c?.doneToday ?? 0)", label: "done today", inverted: true),
            .init(figure: "\((c?.open ?? 0) + (c?.working ?? 0))", label: "open", tap: { s.tab = .board }),
            .init(figure: "\(s.needCount)", label: "need you", red: s.needCount > 0, tap: { s.tab = .needs }),
        ])
    }
}

struct Lane: View {
    @EnvironmentObject var s: Store
    var id: String
    var r: Runner?
    @State private var hover = false

    var state: String { r?.state ?? "offline" }
    var working: Bool { state == "working" || (r?.probe?.generating ?? false) }
    var waiting: Bool { !working && (state == "waiting" || state == "holding") }
    var offline: Bool { r == nil || state == "offline" || (id != "local" && r?.app == false) }
    var active: Bool { (working || waiting) && !offline }

    var word: String { offline ? "Offline" : working ? "Working" : waiting ? "Waiting on you" : "Idle" }
    /// When a runner waits on the owner, its note reads “Chat title”: what it needs. Show that chat, not whichever one is open.
    var waitingOn: (String, String)? {
        guard waiting, let n = r?.note, n.hasPrefix("\u{201C}"), let end = n.dropFirst().firstIndex(of: "\u{201D}") else { return nil }
        let t = String(n[n.index(after: n.startIndex)..<end])
        var rest = String(n[n.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return (t, rest)
    }
    var title: String {
        if let w = waitingOn { return w.0 }
        if let o = r?.probe?.open, !o.isEmpty { return o }
        let t = (r?.text ?? "").replacingOccurrences(of: " TNone", with: "")
        if let a = t.firstIndex(of: "\u{201C}"), let b = t[t.index(after: a)...].firstIndex(of: "\u{201D}") { return String(t[t.index(after: a)..<b]) }
        if id == "local" { return working ? (t.isEmpty ? "Qwen is working" : t) : "Qwen is ready" }
        return t.isEmpty ? (offline ? "Not open" : "Nothing open") : t
    }
    var step: String {
        if let w = waitingOn { return w.1 }
        if let p = r?.probe?.step, !p.isEmpty { return p }
        if let n = r?.note, !n.isEmpty { return n }
        return r?.detail ?? ""
    }

    var body: some View {
        Button { s.backend.openRunner(id) } label: {
            HStack(alignment: .top, spacing: 16) {
                Badge(who: id, filled: active, big: true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Eyebrow(text: word, color: waiting ? D.red : (working ? D.ink : D.quiet))
                        Spacer(minLength: 8)
                        trailing
                    }
                    Text(title).font(D.heading(21)).tracking(-0.8).foregroundStyle(active ? D.ink : D.quiet)
                        .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if !step.isEmpty {
                        Text(step).font(D.a(14)).foregroundStyle(active ? D.body : D.quiet).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.vertical, 16)
            .background(hover ? D.wash : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hover = $0 }
        #endif
    }

    @ViewBuilder var trailing: some View {
        if working, let since = r?.since, since > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { t in
                Text(elapsed(t.date.timeIntervalSince1970 - since)).font(D.mono).foregroundStyle(D.ink)
            }
        } else if waiting {
            Text("Open →").font(D.a(13, 700)).foregroundStyle(D.ink)
        } else {
            Text("—").font(D.mono).foregroundStyle(D.quiet)
        }
    }
}
