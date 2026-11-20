import SwiftUI

/// The companion. Narrow (folded Duo, Mac compact window): one screen at a time with tabs.
/// Wide (unfolded Duo, a wide window): Now stays on the left, the other screens on the right.
public struct CompanionRoot: View {
    public init() {}
    @EnvironmentObject var s: Store
    @StateObject private var ask = AskModel()
    @FocusState private var askFocused: Bool

    public var body: some View {
        GeometryReader { g in
            Group {
                if g.size.width >= 720 { wide } else { narrow }
            }
        }
        #if os(macOS)
        .padding(.top, 26)          // clear the window buttons (hidden title bar)
        #endif
        .background(D.paper)
        .foregroundStyle(D.ink)
        .environment(\.colorScheme, .light)
        .overlay(alignment: .top) {
            if let t = s.toast {
                Text(t).font(D.a(13.5, 700)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(D.ink)
                    .padding(.top, 12).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            ask.store = s
            if let t = ProcessInfo.processInfo.environment["BRIDGE_TAB"], let tab = Store.Tab(rawValue: t) { s.tab = tab }   // for screenshots
        }
        #if os(macOS)
        .background(Button("") { s.tab = .ask; askFocused = true }.keyboardShortcut("k").opacity(0))
        #endif
    }

    var narrow: some View {
        VStack(spacing: 0) {
            Group {
                switch s.tab {
                case .now: NowView()
                case .needs: NeedsView()
                case .board: BoardView()
                case .ask: AskView(m: ask)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            AskBar(m: ask, focused: $askFocused)
            TabBar(items: Store.Tab.allCases)
        }
    }

    var wide: some View {
        HStack(spacing: 0) {
            NowView().frame(width: 400)
            Rectangle().fill(D.ink).frame(width: 2)
            VStack(spacing: 0) {
                HStack(spacing: 22) {
                    ForEach([Store.Tab.needs, .board, .ask], id: \.self) { t in
                        let on = rightTab == t
                        Button { s.tab = t } label: {
                            HStack(spacing: 6) {
                                Text(t == .needs ? "Needs you" : t.rawValue).font(D.a(15, on ? 700 : 500)).foregroundStyle(on ? D.ink : D.quiet)
                                if t == .needs, s.needCount > 0 { RedCount(n: s.needCount) }
                            }
                            .padding(.vertical, 14)
                            .overlay(alignment: .bottom) { Rectangle().fill(on ? D.red : Color.clear).frame(height: 3) }
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .overlay(alignment: .bottom) { Rectangle().fill(D.ink).frame(height: 2) }
                Group {
                    switch rightTab {
                    case .board: BoardView(showTitle: false).padding(.top, 14)
                    case .ask: AskView(m: ask, showTitle: false).padding(.top, 14)
                    default: NeedsView(showTitle: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                AskBar(m: ask, focused: $askFocused)
            }
        }
    }
    /// In the wide layout "Now" is always on screen, so the right side shows the last non-Now tab.
    var rightTab: Store.Tab { s.tab == .now ? .needs : s.tab }
}

struct TabBar: View {
    @EnvironmentObject var s: Store
    var items: [Store.Tab]
    func icon(_ t: Store.Tab) -> String {
        switch t { case .now: return "waveform.path"; case .needs: return "exclamationmark.circle"; case .board: return "list.bullet.rectangle"; case .ask: return "text.bubble" }
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { t in
                let on = s.tab == t
                Button { s.tab = t } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: icon(t)).font(.system(size: 18, weight: on ? .semibold : .regular))
                            if t == .needs, s.needCount > 0 { Rectangle().fill(D.red).frame(width: 7, height: 7).offset(x: 5, y: -2) }
                        }.frame(height: 22)
                        Text(t.rawValue).font(D.a(11.5, on ? 700 : 500))
                    }
                    .foregroundStyle(on ? D.ink : D.quiet)
                    .frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(on ? D.red : Color.clear).frame(height: 3).padding(.horizontal, 10) }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .top) { Rectangle().fill(D.ink).frame(height: 2) }
    }
}

/// Call once at launch, before any view draws.
public func registerBridgeFonts() { D.registerFonts() }
