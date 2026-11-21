#if os(iOS)
import SwiftUI
import UIKit

/// iOS palette: system materials and semantic colours, so light/dark, Liquid Glass and Dynamic Type all work.
/// Brand stays in the accent (bollineni red), the runner tints and Archivo for figures.
enum P {
    static let accent = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.38, blue: 0.30, alpha: 1)
            : UIColor(red: 0xD6 / 255, green: 0x2E / 255, blue: 0x1F / 255, alpha: 1)
    })
    static func tint(_ who: String?) -> Color { (who ?? "") == "naren" ? accent : D.color(who) }
}

/// The iPhone Duo app. Folded: a Liquid Glass tab bar. Unfolded (regular width): a split view with
/// Now in the sidebar and Needs you / Board / Ask on the right.
struct PhoneRoot: View {
    @EnvironmentObject var s: Store
    @StateObject private var ask = AskModel()
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        Group {
            if hsc == .regular { split } else { tabs }
        }
        .tint(P.accent)
        .environmentObject(ask)
        .overlay(alignment: .top) { toast }
        .sensoryFeedback(trigger: s.settled) { old, new in new.count > old.count ? .success : nil }
        .onAppear {
            ask.store = s
            if let t = ProcessInfo.processInfo.environment["BRIDGE_TAB"], let tab = Store.Tab(rawValue: t) { s.tab = tab }
        }
    }

    var tabs: some View {
        TabView(selection: $s.tab) {
            Tab("Now", systemImage: "waveform", value: Store.Tab.now) {
                NavigationStack { PhoneNow() }
            }
            Tab("Needs You", systemImage: "hand.raised", value: Store.Tab.needs) {
                NavigationStack { PhoneNeeds() }
            }
            .badge(s.needCount)
            Tab("Board", systemImage: "checklist", value: Store.Tab.board) {
                NavigationStack { PhoneBoard() }
            }
            Tab("Ask", systemImage: "text.bubble", value: Store.Tab.ask) {
                NavigationStack { PhoneAsk() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(item: $s.replyItem) { n in ReplySheet(n: n).environmentObject(s).presentationDetents([.medium, .large]) }
    }

    var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            PhoneNow()
                .navigationSplitViewColumnWidth(min: 320, ideal: 370, max: 440)
        } detail: {
            TabView(selection: rightTab) {
                Tab("Needs You", systemImage: "hand.raised", value: Store.Tab.needs) {
                    NavigationStack { PhoneNeeds() }
                }
                .badge(s.needCount)
                Tab("Board", systemImage: "checklist", value: Store.Tab.board) {
                    NavigationStack { PhoneBoard() }
                }
                Tab("Ask", systemImage: "text.bubble", value: Store.Tab.ask) {
                    NavigationStack { PhoneAsk() }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Unfolded, Now is always on screen, so the right side shows the last non-Now tab.
    var rightTab: Binding<Store.Tab> {
        Binding(get: { s.tab == .now ? .needs : s.tab }, set: { s.tab = $0 })
    }

    @ViewBuilder var toast: some View {
        if let t = s.toast {
            Text(t)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 11)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Toolbar button on every screen: jump to Ask with the keyboard up.
struct ComposeButton: View {
    @EnvironmentObject var s: Store
    @EnvironmentObject var m: AskModel
    var body: some View {
        Button {
            m.wantsFocus = true
            s.tab = .ask
        } label: {
            Label("Ask", systemImage: "square.and.pencil")
        }
    }
}

/// Runner avatar: a squircle filled with the runner's tint while it works, a quiet fill when it doesn't.
struct RunnerAvatar: View {
    var who: String?
    var on: Bool
    var size: CGFloat = 40
    var body: some View {
        Text(D.code(who))
            .font(.system(size: size * 0.27, weight: .heavy, design: .rounded))
            .foregroundStyle(on ? Color.black.opacity(0.85) : Color.secondary)
            .frame(width: size, height: size)
            .background(on ? AnyShapeStyle(P.tint(who)) : AnyShapeStyle(Color(.tertiarySystemFill)),
                        in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityLabel(D.name(who))
    }
}

/// Small status capsule ("Working", "Waiting on you", "Done").
struct StatusPill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .capsule)
    }
}
#endif
