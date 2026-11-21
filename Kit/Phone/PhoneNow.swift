#if os(iOS)
import SwiftUI

/// Now: the day at a glance (Reminders-style tiles), then the three runners.
struct PhoneNow: View {
    @EnvironmentObject var s: Store
    @EnvironmentObject var link: PhoneLink

    var body: some View {
        List {
            if s.stale {
                Section {
                    Label(s.staleText + " · " + s.backend.name, systemImage: "icloud.slash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(P.accent)
                }
            }
            Section {
                tiles
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(["ultra", "pro", "local"], id: \.self) { id in
                    RunnerRow(id: id, r: s.runner(id))
                }
            } header: {
                Text("Runners")
            } footer: {
                if !s.stale { Text(s.staleText) }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .navigationTitle("Bridge")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ComposeButton() } }
        .refreshable { await link.pull() }
    }

    var tiles: some View {
        let c = s.snap.counts
        return HStack(spacing: 10) {
            StatTile(figure: c?.doneToday ?? 0, label: "Done today", symbol: "checkmark.circle.fill", color: .green)
            StatTile(figure: (c?.open ?? 0) + (c?.working ?? 0), label: "Open", symbol: "circle.dashed", color: .blue) { s.tab = .board }
            StatTile(figure: s.needCount, label: "Need you", symbol: "hand.raised.fill",
                     color: s.needCount > 0 ? P.accent : .secondary) { s.tab = .needs }
        }
    }
}

struct StatTile: View {
    var figure: Int
    var label: String
    var symbol: String
    var color: Color
    var tap: (() -> Void)? = nil

    var body: some View {
        Button { tap?() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(color)
                    Spacer(minLength: 4)
                    Text("\(figure)")
                        .font(D.heading(28)).monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.primary)
                }
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(tap != nil)
        .animation(.snappy, value: figure)
        .accessibilityElement(children: .combine)
    }
}

struct RunnerRow: View {
    @EnvironmentObject var s: Store
    var id: String
    var r: Runner?

    var body: some View {
        let l = Lane(id: id, r: r)
        let pillColor: Color = l.waiting ? P.accent : (l.working ? P.tint(id) : .secondary)
        Button { s.backend.openRunner(id) } label: {
            HStack(alignment: .top, spacing: 12) {
                RunnerAvatar(who: id, on: l.active)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(D.name(id)).font(.headline)
                        StatusPill(text: l.word, color: pillColor)
                        Spacer(minLength: 4)
                        if l.working, let since = r?.since, since > 0 {
                            TimelineView(.periodic(from: .now, by: 1)) { t in
                                Text(elapsed(t.date.timeIntervalSince1970 - since))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(l.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(l.active ? .primary : .secondary)
                        .lineLimit(2)
                    if !l.step.isEmpty {
                        Text(l.step).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .tint(.primary)
        .contextMenu {
            if id != "local" {
                Button("Open in Claude", systemImage: "arrow.up.forward.app") { s.backend.openRunner(id) }
            }
        }
    }
}
#endif
