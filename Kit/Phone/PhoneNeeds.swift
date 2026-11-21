#if os(iOS)
import SwiftUI

/// Needs you: only what the owner can act on. Swipe right to finish, left to open or deny.
struct PhoneNeeds: View {
    @EnvironmentObject var s: Store
    @EnvironmentObject var link: PhoneLink

    var body: some View {
        let all = s.needs
        let mine = all.filter { $0.kind != .approval }
        let groups: [(String, [NeedItem])] = [
            ("Approvals", s.approvals),
            ("Today", mine.filter { $0.kind == .need || dueDays($0.due) <= 0 }),
            ("This Week", mine.filter { $0.kind == .task && (1...7).contains(dueDays($0.due)) }),
            ("Later", mine.filter { $0.kind == .task && dueDays($0.due) > 7 }),
        ].filter { !$0.1.isEmpty }

        List {
            ForEach(groups, id: \.0) { g in
                Section(g.0) {
                    ForEach(g.1) { n in NeedRowP(n: n) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if all.isEmpty {
                ContentUnavailableView("Nothing Needs You", systemImage: "checkmark.seal",
                                       description: Text("Ultra, Pro and Qwen are covering it."))
            }
        }
        .animation(.default, value: all.map(\.id))
        .navigationTitle("Needs You")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ComposeButton() } }
        .refreshable { await link.pull() }
    }
}

struct NeedRowP: View {
    @EnvironmentObject var s: Store
    var n: NeedItem
    var late: Bool { dueDays(n.due) < 0 }
    var meta: String { [dueText(n.due), n.detail].filter { !$0.isEmpty }.joined(separator: " · ") }
    var primary: String { n.kind == .approval ? "Approve" : "Done" }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title).font(.body).lineLimit(3)
                HStack(spacing: 6) {
                    Text(n.code).monospaced()
                    if !meta.isEmpty {
                        Text(meta).foregroundStyle(late ? P.accent : .secondary)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if s.busy.contains(n.id) {
                ProgressView()
            } else {
                Button(primary) { s.complete(n) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { s.complete(n) } label: { Label(primary, systemImage: "checkmark") }.tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if n.kind == .approval {
                Button(role: .destructive) { s.deny(n) } label: { Label("Deny", systemImage: "xmark") }
            } else if n.url != nil {
                Button { s.open(n) } label: { Label("Open", systemImage: "safari") }.tint(.blue)
            }
        }
        .contextMenu {
            Button(primary, systemImage: "checkmark") { s.complete(n) }
            if n.kind == .approval { Button("Deny", systemImage: "xmark", role: .destructive) { s.deny(n) } }
            if n.url != nil { Button("Open", systemImage: "safari") { s.open(n) } }
        }
    }
}
#endif
