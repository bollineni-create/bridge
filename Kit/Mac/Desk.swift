#if os(macOS)
import SwiftUI

/// Bridge's main window, built from the same parts as the iPhone Duo app (bollineni.co "Swiss Tombstone"):
/// heavy wide titles, joined tombstone figures, ruled lanes, square black buttons, one red.

/// Command: the day in tombstones, the three runners side by side, then what needs you and what is next.
public struct DeskCommand: View {
    public init() {}
    @EnvironmentObject var s: Store
    @StateObject private var ask = AskModel()
    @FocusState private var askFocused: Bool

    var upNext: [BTask] {
        s.tasks.filter { !$0.isDone && !["naren", "parked"].contains($0.forWho ?? "") && !s.settled.contains("T\($0.id)") }
            .sorted { (($0.live ?? false) ? -1 : dueDays($0.due)) < (($1.live ?? false) ? -1 : dueDays($1.due)) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            Scroller {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.bottom, 26)
                    stones
                    lanes.padding(.top, 34)
                    if let last = ask.entries.last {
                        Eyebrow(text: "Asked").padding(.top, 34).padding(.bottom, 12)
                        AskTurn(e: last, m: ask)
                    }
                    HStack(alignment: .top, spacing: 48) {
                        needs.frame(maxWidth: .infinity, alignment: .topLeading)
                        next.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(.top, 40)
                }
                .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 24)
                .frame(maxWidth: 1240, alignment: .leading)
            }
            Rule(heavy: true)
            AskBar(m: ask, focused: $askFocused).padding(.horizontal, 16).padding(.vertical, 6)
        }
        .background(D.paper)
        .environment(\.colorScheme, .light)
        .onAppear { ask.store = s }
        .background(Button("") { askFocused = true }.keyboardShortcut("k").opacity(0))
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("Command").font(D.display(44)).tracking(-2.2).foregroundStyle(D.ink)
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(D.a(16)).foregroundStyle(D.quiet)
            Spacer()
            if s.needCount > 0 { RedCount(n: s.needCount, words: true) }
            else { Text("All clear").font(D.a(14, 600)).foregroundStyle(D.quiet) }
        }
    }

    var stones: some View {
        let c = s.snap.counts
        return Tombstones(stones: [
            .init(figure: "\(c?.doneToday ?? 0)", label: "done today", inverted: true),
            .init(figure: "\(c?.working ?? 0)", label: "moving"),
            .init(figure: "\(c?.open ?? 0)", label: "open"),
            .init(figure: "\(s.needCount)", label: "need you", red: s.needCount > 0),
        ], size: 46)
    }

    var lanes: some View {
        VStack(spacing: 0) {
            Rule(heavy: true)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(["ultra", "pro", "local"].enumerated()), id: \.1) { i, id in
                    if i > 0 { Rectangle().fill(D.ink).frame(width: 1) }
                    Lane(id: id, r: s.runner(id))
                        .padding(.leading, i == 0 ? 0 : 22).padding(.trailing, i == 2 ? 0 : 22)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Rule()
        }
    }

    var needs: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Needs you").font(D.heading(24)).tracking(-0.9)
                if s.needCount > 0 { RedCount(n: s.needCount) }
                Spacer()
            }.padding(.bottom, 12)
            Rule(heavy: true)
            if s.needs.isEmpty { EmptyNote(text: "Nothing needs you.", sub: "Ultra, Pro and Qwen are covering it.") }
            ForEach(s.needs.prefix(8)) { n in NeedRow(n: n); Rule() }
        }
    }

    var next: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up next").font(D.heading(24)).tracking(-0.9).padding(.bottom, 12)
            Rule(heavy: true)
            if upNext.isEmpty { EmptyNote(text: "The board is clear.", sub: "") }
            ForEach(upNext.prefix(8)) { t in BoardRow(t: t); Rule() }
        }
    }
}

/// Board and Needs you, at desktop size: the companion screens with room to breathe.
public struct DeskBoard: View {
    public init() {}
    public var body: some View {
        BoardView().padding(.horizontal, 16).padding(.top, 20).frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(D.paper).environment(\.colorScheme, .light)
    }
}
public struct DeskNeeds: View {
    public init() {}
    public var body: some View {
        NeedsView().padding(.horizontal, 16).padding(.top, 20).frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(D.paper).environment(\.colorScheme, .light)
    }
}
#endif
