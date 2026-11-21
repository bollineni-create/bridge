import SwiftUI
import AppKit

enum Ink {
    // System colors only, so Bridge follows light and dark mode, contrast settings and the accent colour like any Apple app.
    // Apple's grouped-list pair (systemGroupedBackground + secondarySystemGroupedBackground): grey page, white cells; dark: #1C1C1E and #2C2C2E.
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    static let bg = adaptive(NSColor.white,   // bollineni.co paper (Swiss Tombstone, Nov 20)
                              NSColor.black)   // dark mode: true black, matches DS.bg
    static let bg2 = bg
    static let panel = adaptive(.white, NSColor(white: 0x1E / 255.0, alpha: 1))
    static let line = Color(nsColor: .separatorColor)
    static let ink = Color.primary
    static let ultra = Color.orange
    static let pro = Color.purple
    static let mac = Color.teal
    static let good = Color.green
    static let warn = Color.orange
    static let bad = Color(red: 0.839, green: 0.180, blue: 0.122)   // #D62E1F
    static let dim = Color.secondary
    static let faint = Color(nsColor: .tertiaryLabelColor)

    static func runner(_ id: String?) -> Color {
        switch id ?? "" {
        case "ultra": return ultra
        case "pro": return pro
        case "local": return mac
        case "naren": return warn
        default: return dim
        }
    }

    static func state(_ s: String) -> Color {
        switch s {
        case "working": return good
        case "ready": return mac
        case "holding", "waiting": return warn
        case "idle": return Color(red: 0.45, green: 0.62, blue: 0.95)
        case "ok", "fixed": return good
        case "problem": return bad
        default: return faint
        }
    }

    static func who(_ id: String?) -> String {
        switch id ?? "" {
        case "ultra": return "Ultra"
        case "pro": return "Pro"
        case "local": return "This Mac"
        case "naren": return "You"
        case "any": return "Any runner"
        case "parked": return "Parked"
        default: return (id ?? "").capitalized
        }
    }
}

/// The mark: one span, three anchors (Ultra, Pro, this Mac), one deck.
struct BridgeMark: View {
    var size: CGFloat = 28
    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            let a = CGPoint(x: w * 0.12, y: h * 0.72), b = CGPoint(x: w * 0.88, y: h * 0.72), c = CGPoint(x: w * 0.50, y: h * -0.06)
            func at(_ t: CGFloat) -> CGPoint {
                let u = 1 - t
                return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
            }
            for t in [0.22, 0.36, 0.64, 0.78] as [CGFloat] {
                var s = Path()
                let p = at(t)
                s.move(to: p)
                s.addLine(to: CGPoint(x: p.x, y: h * 0.72))
                ctx.stroke(s, with: .color(.white.opacity(0.38)), lineWidth: max(1, w * 0.028))
            }
            var arc = Path()
            arc.move(to: a)
            arc.addQuadCurve(to: b, control: c)
            ctx.stroke(arc, with: .linearGradient(Gradient(colors: [Ink.ultra, Ink.pro, Ink.mac]), startPoint: a, endPoint: b), style: StrokeStyle(lineWidth: w * 0.085, lineCap: .round))
            var deck = Path()
            deck.move(to: CGPoint(x: w * 0.03, y: h * 0.72))
            deck.addLine(to: CGPoint(x: w * 0.97, y: h * 0.72))
            ctx.stroke(deck, with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: w * 0.06, lineCap: .round))
            let nodes: [(CGFloat, Color)] = [(0, Ink.ultra), (0.5, Ink.pro), (1, Ink.mac)]
            for (t, col) in nodes {
                let p = at(t), r = w * 0.095
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(col))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.42, y: p.y - r * 0.42, width: r * 0.84, height: r * 0.84)), with: .color(.white))
            }
        }
        .frame(width: size, height: size)
    }
}

struct LiveDot: View {
    var color: Color
    var pulse = false
    @State private var on = false
    var body: some View {
        ZStack {
            if pulse { Circle().stroke(color.opacity(0.6), lineWidth: 1.5).frame(width: 8, height: 8).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.9) }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
        .onAppear { if pulse { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } } }
    }
}

struct Pill: View {
    var text: String
    var color: Color = Ink.dim
    var body: some View {
        Text(text).font(SW.a(11.5, 600)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Rectangle())
    }
}

struct Card<Content: View>: View {    // bollineni.co: content sits on the page under a 2px black rule, no box
    var pad: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.vertical, pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(DS.rule).frame(height: 2) }
    }
}

struct Heading: View {
    var text: String
    var note: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(SW.a(15, 600))
            if !note.isEmpty { Text(note).font(SW.a(13, 400)).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.top, 10).padding(.leading, 4)
    }
}

/// States exactly how fresh a feed is. Stale data never looks live.
struct Freshness: View {
    var feed: Feed?
    var body: some View {
        if let f = feed {
            if f.fresh {
                HStack(spacing: 2) { LiveDot(color: Ink.good, pulse: true); Text("Live · \(ago(f.asOf))").font(SW.a(13, 500)).foregroundStyle(Ink.good) }
            } else {
                HStack(spacing: 2) { LiveDot(color: Ink.warn); Text("Stale · " + ((f.detail ?? "").isEmpty ? "updated \(ago(f.asOf))" : (f.detail ?? ""))).font(SW.a(13, 500)).foregroundStyle(Ink.warn).lineLimit(2) }
            }
        } else {
            Text("No data").font(SW.a(13, 400)).foregroundStyle(Ink.faint)
        }
    }
}

struct Page<Content: View>: View {
    var title: String
    var subtitle: String = ""
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(SW.display(34)).tracking(-1.6)
                        if !subtitle.isEmpty { Text(subtitle).font(SW.a(14, 400)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let t = trailing { t }
                }
                .padding(.bottom, 4)
                content
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.bg)
    }
}

/// A tinted capsule button, the standard secondary button shape in the current Apple design.
struct QuietButton: ButtonStyle {    // bollineni.co .btn: square, 2px border, red when pressed
    var color: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        let hot = configuration.isPressed
        let c = color == .accentColor ? Ink.ink : color
        configuration.label.font(SW.a(13.5, 700)).foregroundStyle(hot ? Color.white : c)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(hot ? SW.red : Color.clear)
            .overlay(Rectangle().strokeBorder(hot ? SW.red : c, lineWidth: 2))
            .contentShape(Rectangle())
    }
}

/// Settings-style icon tile for the sidebar.
struct SidebarIcon: View {
    var symbol: String
    var tint: Color
    var body: some View {
        // Design system IconTile: neutral fill, label glyph. No per-pane rainbow (Nov 19, 2026).
        Image(systemName: symbol).font(SW.a(12, 500)).foregroundStyle(DS.label)
            .frame(width: 26, height: 26)
            .background(DS.fill, in: Rectangle())
    }
}

extension Pane {
    var tint: Color {
        switch self {
        case .command: return .blue
        case .board: return .indigo
        case .needs: return .orange
        case .calendar: return .red
        case .reminders: return .blue
        case .messages: return .green
        case .mail: return .blue
        case .notes: return .yellow
        case .contacts: return .brown
        case .browser: return .cyan
        case .music: return .pink
        case .location: return .blue
        case .apps: return .indigo
        case .system: return .gray
        case .shortcuts: return .orange
        case .vault: return .green
        case .activity: return .teal
        case .health: return .pink
        case .settings: return .gray
        case .context: return .blue
        case .qwen: return .teal
        }
    }
}

// MARK: Civic layer (design system, Nov 19, 2026)
// Borrowed from the National Design Studio sites: mono eyebrows (OPM, Genesis Mission), the live strip (gov banner + Genesis clock),
// huge tight numerals (Tech Force, SI.gov) and one ease for motion (SI.gov).
enum Civic {
    static let ease = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)
}

/// SF Mono capitals, 2pt tracking, above a section title or the hero count. Never alone.
struct Eyebrow: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).textCase(.uppercase).tracking(2).foregroundStyle(.secondary)
    }
}

/// The strip across the top of every pane: is the engine live, how fresh is this, the clock.
struct StatusStrip: View {
    @EnvironmentObject var store: Store
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tl in
            let s = store.snap
            let age = s.map { tl.date.timeIntervalSince1970 - $0.generated } ?? .infinity
            let live = age < 10
            let stale = s.map { $0.feeds.values.filter { !$0.fresh }.count } ?? 0
            let up = s.map { $0.runners.filter { !["offline", "unknown"].contains($0.state) }.count } ?? 0
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    if live { Circle().fill(Ink.good).frame(width: 6, height: 6) }
                    else { Rectangle().fill(Ink.warn).frame(width: 5, height: 5).rotationEffect(.degrees(45)) }
                    Text(live ? "Engine live" : "Engine stale").foregroundStyle(live ? Color.primary : Ink.warn)
                }
                dot
                Text(s == nil ? "No reading yet" : (live ? "Synced \(max(0, Int(age)))s ago" : "Last reading \(ago(s!.generated))"))
                dot
                Text("\(up) of \(s?.runners.count ?? 3) runners up · " + (stale == 0 ? "all feeds live" : "\(stale) feed\(stale == 1 ? "" : "s") stale"))
                Spacer(minLength: 8)
                Text(tl.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced)).textCase(.uppercase).tracking(0.6).monospacedDigit()
            .foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 16).frame(height: 28).padding(.top, 8)
            .background(DS.bg)
            .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: 0.5) }
        }
    }
    var dot: some View { Text("·").foregroundStyle(Ink.faint) }
}

/// Command's hero: the one big count of the day, tracked tight, with the day's progress line.
struct TodayHero: View {
    var done: Int
    var total: Int
    var body: some View {
        let v = total == 0 ? 0 : min(1, Double(done) / Double(total))
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Today")
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(done)").font(.system(size: 72, weight: .bold, design: .rounded)).tracking(-3).monospacedDigit()
                        .contentTransition(.numericText()).animation(Civic.ease, value: done)
                    Text("of \(total) done").font(SW.a(18, 700, width: 112)).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 66)
                GeometryReader { g in
                    let x = max(7, min(g.size.width - 7, g.size.width * v))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Ink.faint).frame(height: 2)
                        Rectangle().fill(Color.primary).frame(width: x, height: 6)
                        Circle().fill(Color.primary).frame(width: 14, height: 14).offset(x: x - 7)
                    }
                    .frame(height: 14).animation(Civic.ease, value: v)
                }
                .frame(height: 14)
            }
        }
    }
}
