import SwiftUI
import AppKit

// Window shell built to the Bridge design system mockup (Nov 19, 2026): a floating white sidebar panel inset from the window
// edge on warm paper, neutral icon tiles (accent tile on the selected row), counts on the right, caps section labels.
// The title bar is hidden; the traffic lights sit on the sidebar panel and the StatusStrip runs across the top of the detail.

struct SidebarDS: View {
    @EnvironmentObject var store: Store
    @Binding var pane: Pane

    func count(_ p: Pane) -> (Int, Bool)? {
        guard let s = store.snap else { return nil }
        switch p {
        case .needs: let n = s.counts.needs + s.counts.naren; return n > 0 ? (n, true) : nil
        case .board: let n = s.counts.open + s.counts.working; return n > 0 ? (n, false) : nil
        case .messages: let n = (s.feeds["messages"]?.items ?? []).reduce(0) { $0 + ($1.unread ?? 0) }; return n > 0 ? (n, false) : nil
        case .mail: let n = (s.feeds["mail"]?.items ?? []).reduce(0) { $0 + ($1.unread ?? 0) }; return n > 0 ? (n, false) : nil
        default: return nil
        }
    }

    func row(_ p: Pane, _ title: String? = nil) -> some View {
        let on = pane == p
        return Button { pane = p } label: {
            HStack(spacing: 10) {
                Image(systemName: p.dsIcon).font(SW.a(12, 500))
                    .foregroundStyle(on ? Color.white : SW.nightQuiet)
                    .frame(width: 26, height: 26)
                Text(title ?? p.title).font(SW.a(15, on ? 600 : 400)).foregroundStyle(on ? Color.white : SW.nightQuiet).lineLimit(1)
                Spacer(minLength: 4)
                if let c = count(p) { DSCount(n: c.0, quiet: !c.1) }
            }
            .padding(.horizontal, 8).frame(height: 38)
            .background(on ? Color.white.opacity(0.08) : Color.clear)
            .overlay(alignment: .leading) { Rectangle().fill(on ? SW.red : Color.clear).frame(width: 3) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func section(_ t: String) -> some View {
        DS.caps(t).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                Color.clear.frame(height: 30)          // the traffic lights sit here
                HStack(spacing: 10) {
                    HStack(alignment: .center, spacing: 3) {
                        Capsule().fill(DS.ultra).frame(width: 4, height: 9)
                        Capsule().fill(DS.pro).frame(width: 4, height: 14)
                        Capsule().fill(DS.mac).frame(width: 4, height: 20)
                    }
                    .frame(height: 20)
                    (Text("Bridge").foregroundColor(.white) + Text(".").foregroundColor(SW.red)).font(SW.display(24)).tracking(-1.2)
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
                row(.command); row(.board); row(.needs); row(.qwen, "Qwen")
                section("Feeds")
                row(.calendar); row(.reminders); row(.messages); row(.mail); row(.notes)
                section("Control")
                row(.apps); row(.vault); row(.health); row(.settings)
                section("More")
                row(.context); row(.shortcuts); row(.activity)
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)     // the night room: the one dark surface, as on bollineni.co
    }
}

/// Segmented control from the mockup: fill track, the selected segment a solid label-coloured capsule.
struct DSSegmented: View {        // bollineni.co nav: underline tabs, red bar under the selected one
    @Binding var value: String
    var options: [(String, String)]
    var body: some View {
        HStack(spacing: 18) {
            ForEach(options, id: \.0) { o in
                let on = value == o.0
                Button { withAnimation(Civic.ease) { value = o.0 } } label: {
                    Text(o.1).font(SW.a(15, on ? 700 : 500)).foregroundStyle(on ? DS.label : DS.label2)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? SW.red : Color.clear).frame(height: 3).offset(y: 3) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension Pane {
    /// Line glyphs for the neutral tiles (SF Symbols).
    var dsIcon: String {
        switch self {
        case .command: return "square.grid.2x2"
        case .board: return "list.bullet"
        case .needs: return "bell"
        case .qwen: return "bubble.left"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .messages: return "message"
        case .mail: return "envelope"
        case .notes: return "doc.text"
        case .apps: return "square.stack.3d.up"
        case .vault: return "lock"
        case .health: return "waveform.path.ecg"
        case .settings: return "slider.horizontal.3"
        case .context: return "square.stack"
        case .shortcuts: return "alarm"
        case .activity: return "clock.arrow.circlepath"
        default: return icon
        }
    }
}
