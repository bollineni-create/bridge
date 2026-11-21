import SwiftUI
import CoreText

// The island's parts, shared by the Live Activity (Widget/BridgeWidget.swift) and the big island panel in the app
// (App/NotchPanel.swift). Every part takes one scale factor `k`; nothing here sets a width.
//
// Swiss Tombstone, night room (Nov 20, 2026): the same system as Bridge.app and the companion (Companion/Kit/Shared/Theme.swift).
//  - Black ground, white ink, one red (#D62E1F). Square corners everywhere: no capsules, no rounded rects.
//  - Archivo for counts and words (heavy + wide for figures), SF Mono for runner codes and task IDs.
//  - IslandRunner tint only while the runner works or holds (the site's launcher rule); idle / offline is a grey outline.
//  - Layout A (Nov 20): small day count, the task at hand as the hero, three runner tiles in their colours.
// Previous design: backup-pre-swiss-la-20261120-0554/.

enum Glance {
    typealias S = BridgeAttributes.ContentState
    // Companion tokens (D.*): runner tints, the red, and the night-room greys.
    static let ultra = Color(red: 1.000, green: 0.624, blue: 0.039)      // #FF9F0A
    static let pro = Color(red: 0.749, green: 0.353, blue: 0.949)        // #BF5AF2
    static let mac = Color(red: 0.251, green: 0.784, blue: 0.878)        // #40C8E0
    static let need = Color(red: 0.839, green: 0.180, blue: 0.122)       // #D62E1F, D.red / SW.red
    static let body = Color(red: 0.855, green: 0.855, blue: 0.855)       // #DADADA, D.nightBody
    static let second = Color(red: 0.659, green: 0.659, blue: 0.659)     // #A8A8A8, D.nightQuiet
    static let third = Color(red: 0.420, green: 0.420, blue: 0.420)      // #6B6B6B, off / track
    static let line = Color(red: 0.188, green: 0.188, blue: 0.188)       // #303030, D.nightLine

    // MARK: Archivo (variable: wght 100–900, wdth 62–125). Bundled into the widget extension; the app registers it via BridgeKit.
    private static let fontsReady: Bool = {
        for b in [Bundle.main, Bundle(for: FontToken.self)] {
            if let u = b.url(forResource: "Archivo", withExtension: "ttf") { CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil) }
        }
        return true
    }()
    private final class FontToken {}
    static func a(_ size: CGFloat, _ weight: CGFloat = 400, width: CGFloat = 100) -> Font {
        _ = fontsReady
        let attrs: [CFString: Any] = [kCTFontNameAttribute: "Archivo", kCTFontVariationAttribute: [0x77676874: weight, 0x77647468: width]]
        let ct = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
        if (CTFontCopyFamilyName(ct) as String).hasPrefix("Archivo") { return Font(ct) }
        return .system(size: size, weight: weight >= 800 ? .heavy : weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
    }
    static func figure(_ size: CGFloat) -> Font { a(size, 800, width: 112) }   // D.heading
    static func mono(_ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .system(size: size, weight: w, design: .monospaced) }

    static func active(_ state: String) -> Bool { state == "working" || state == "holding" || state == "waiting" }
    static func off(_ state: String) -> Bool { state == "offline" || state == "unknown" }
    static func height(_ state: String) -> CGFloat {
        switch state {
        case "working": return 18
        case "holding": return 12
        case "waiting": return 12
        case "ready": return 9
        case "idle", "away": return 6
        default: return 4
        }
    }
    static func word(_ state: String) -> String {
        switch state {
        case "working": return "Working"
        case "holding": return "Holding"
        case "waiting": return "Your turn"
        case "ready": return "Ready"
        case "idle": return "Idle"
        case "away": return "Away"
        default: return "Offline"
        }
    }
    static func total(_ s: S) -> Int { s.done + s.openCount }
    static func progress(_ s: S) -> Double { total(s) == 0 ? 0 : Double(s.done) / Double(total(s)) }
    static func isTask(_ t: String) -> Bool { t.count >= 2 && t.count <= 5 && t.hasPrefix("T") && t.dropFirst().allSatisfy(\.isNumber) }
    /// "T39 Test failover handoff" → ("T39", "Test failover handoff"); a chat title with no task → ("", title).
    static func split(_ on: String) -> (id: String, title: String) {
        let parts = on.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first, isTask(first) else { return ("", on) }
        return (first, parts.count > 1 ? parts[1] : "")
    }
    /// The task ID in motion, working runner first.
    static func motion(_ s: S) -> String {
        let order = [(s.local, s.localOn), (s.ultra, s.ultraOn), (s.pro, s.proOn)].sorted { active($0.0) && !active($1.0) }
        return order.map { split($0.1).id }.first(where: { !$0.isEmpty }) ?? ""
    }
    /// The one short value beside the count in the menu bar: what needs him, else the task in motion, else "Quiet".
    static func trail(_ s: S) -> String { s.mine > 0 ? "\(s.mine)" : (motion(s).isEmpty ? "Quiet" : motion(s)) }
    static func trailInk(_ s: S) -> Color { s.mine > 0 ? .white : (motion(s).isEmpty ? second : .white) }
    static func trailFill(_ s: S) -> Color { s.mine > 0 ? need : .clear }
    /// A click goes where the work is: Needs You if something waits on him, else the app of the runner that is working.
    static func url(_ s: S) -> URL? {
        if s.mine > 0 || s.needs > 0 { return URL(string: "bridge://needs") }
        if active(s.ultra) { return URL(string: "bridge://open/ultra") }
        if active(s.pro) { return URL(string: "bridge://open/pro") }
        if active(s.local) { return URL(string: "bridge://open/local") }
        return URL(string: "bridge://command")
    }
}

/// RunnerBars: three square bars, always Ultra · Pro · Mac. Height is the state; tint only while active. (Compact + minimal island.)
struct RunnerBars: View {
    let s: BridgeAttributes.ContentState
    var scale: CGFloat = 1
    func bar(_ state: String, _ c: Color) -> some View {
        Rectangle().fill(Glance.off(state) ? Glance.third : (Glance.active(state) ? c : Glance.second))
            .frame(width: 4 * scale, height: Glance.height(state) * scale)
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 3 * scale) {
            bar(s.ultra, Glance.ultra); bar(s.pro, Glance.pro); bar(s.local, Glance.mac)
        }
        .frame(height: 18 * scale, alignment: .bottom)
    }
}

/// The three runners in a fixed order, with what each holds.
struct IslandRunner { let id, code: String; let color: Color; let state, on: String; let since: Date? }
extension Glance {
    static func name(_ id: String) -> String { id == "ultra" ? "Ultra" : id == "pro" ? "Pro" : "Mac" }
    static func runners(_ s: S) -> [IslandRunner] {
        [IslandRunner(id: "ultra", code: "ULT", color: ultra, state: s.ultra, on: s.ultraOn, since: s.ultraSince),
         IslandRunner(id: "pro", code: "PRO", color: pro, state: s.pro, on: s.proOn, since: s.proSince),
         IslandRunner(id: "local", code: "MAC", color: mac, state: s.local, on: s.localOn, since: s.localSince)]
    }
    /// The task at hand: the runner that started working most recently, else one holding or waiting on him.
    static func current(_ s: S) -> IslandRunner? {
        let rs = runners(s)
        // A working runner always leads, even if its status names no task (then `task(_:_:)` falls back to the board's list).
        let working = rs.filter { $0.state == "working" }
        if let r = working.max(by: { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }) { return r }
        return rs.first { active($0.state) && !$0.on.isEmpty }
    }
    /// What the runner is on: its own status, else its line in the board's "working" list ("Pro · T3 Credit re-freeze").
    static func task(_ r: IslandRunner, _ s: S) -> String {
        if !r.on.isEmpty { return r.on }
        let name = r.id == "local" ? ["mac", "local", "this mac"] : [r.id]
        for w in s.working {
            let parts = w.components(separatedBy: " · ")
            if parts.count > 1, name.contains(parts[0].lowercased()) { return parts.dropFirst().joined(separator: " · ") }
        }
        return ""
    }
}

/// RunnerBadge: the companion's square chip. Filled with the tint while the runner works or holds, grey outline otherwise.
struct RunnerBadge: View {
    let code: String
    let color: Color
    var lit = true
    var k: CGFloat = 1
    var body: some View {
        Text(code)
            .font(Glance.mono(11 * k)).tracking(0.5 * k)
            .foregroundStyle(lit ? Color.black : Glance.second)
            .lineLimit(1).fixedSize()
            .frame(width: 36 * k, height: 20 * k)
            .background(lit ? color : Color.clear)
            .overlay(Rectangle().strokeBorder(lit ? Color.clear : Glance.third, lineWidth: 1 * k))
    }
}

/// Header, left: who holds the task at hand (code in its colour), the task ID and the timer. Plain type, no box:
/// the working tile below already carries the colour. With nothing running, a quiet "NOW".
struct IslandHead: View {
    let s: BridgeAttributes.ContentState
    var k: CGFloat = 1
    var body: some View {
        let id = Glance.current(s).map { Glance.split(Glance.task($0, s)).id } ?? ""
        let label = s.waiting.isEmpty || Glance.current(s) != nil ? "Now" : "Up next"
        Text(id.isEmpty ? label : "\(label) · \(id)")
            .font(Glance.mono(12 * k, .semibold)).textCase(.uppercase).tracking(1.2 * k)
            .foregroundStyle(Glance.second).lineLimit(1).fixedSize()
    }
}

/// Header, right: the day's count as a small detail, then a red square with how many things need him.
struct IslandNeed: View {
    let s: BridgeAttributes.ContentState
    var k: CGFloat = 1
    var body: some View {
        HStack(spacing: 8 * k) {
            Text("\(s.done)/\(Glance.total(s))").font(Glance.mono(12 * k, .medium)).monospacedDigit()
                .foregroundStyle(Glance.second).lineLimit(1).fixedSize()
            if s.mine > 0 {
                Text("\(s.mine)").font(Glance.a(13 * k, 800, width: 112)).monospacedDigit()
                    .foregroundStyle(Color.white).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6 * k).frame(minWidth: 22 * k, minHeight: 22 * k)
                    .background(Glance.need)
            }
        }
    }
}

/// Kept for anything still asking for the old top-left count: it is the header now.
typealias IslandCount = IslandHead

/// One runner column (design C, Nov 21): a colour bar on top (full when working or holding, faded when ready/idle,
/// grey when offline), the code, then the timer while working or the state word.
struct RunnerTile: View {
    let r: IslandRunner
    var k: CGFloat = 1
    var body: some View {
        let working = r.state == "working"
        let lit = Glance.active(r.state)
        let off = Glance.off(r.state)
        Link(destination: URL(string: "bridge://open/" + r.id)!) {
            VStack(alignment: .leading, spacing: 5 * k) {
                Rectangle().fill(off ? Glance.third : r.color.opacity(lit ? 1 : (r.state == "ready" ? 0.45 : 0.25)))
                    .frame(height: 4 * k)
                VStack(alignment: .leading, spacing: 1 * k) {
                    Text(r.code).font(Glance.mono(11 * k)).tracking(0.8 * k).foregroundStyle(lit ? r.color : (off ? Glance.third : Glance.second))
                    if working, let d = r.since {
                        Text(d, style: .timer).font(Glance.a(13 * k, 700)).monospacedDigit().foregroundStyle(Color.white).lineLimit(1)
                    } else {
                        Text(Glance.word(r.state)).font(Glance.a(13 * k, lit ? 700 : 500))
                            .foregroundStyle(lit ? Color.white : (off ? Glance.third : Glance.second)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Glance {
    static let wash = Color(red: 0.094, green: 0.094, blue: 0.094)   // #181818, the night room's resting tile
}

/// Below the header: the task title as the hero, then the three runner tiles.
/// Sized for Apple's 160 pt Live Activity limit at Big.k (measured with _measure/fit.sh).
struct IslandLanes: View {
    let s: BridgeAttributes.ContentState
    var k: CGFloat = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 12 * k) {
            Group {
                if let r = Glance.current(s) {
                    let on = Glance.task(r, s)
                    let t = Glance.split(on)
                    let title = on.isEmpty ? "\(Glance.name(r.id)) is working" : (t.title.isEmpty ? (t.id.isEmpty ? on : t.id) : t.title)
                    Link(destination: URL(string: "bridge://open/" + r.id)!) {
                        Text(title).font(Glance.a(19 * k, 700, width: 100)).tracking(-19 * k * 0.015).foregroundStyle(Color.white)
                            .lineLimit(1).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if let next = s.waiting.first {
                    // Nothing running: the next thing on the board takes the hero spot, so the island stays useful (Nov 21).
                    Link(destination: URL(string: "bridge://needs")!) {
                        Text(next).font(Glance.a(19 * k, 700, width: 100)).tracking(-19 * k * 0.015).foregroundStyle(Glance.body)
                            .lineLimit(1).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 0) {
                        Text("Nothing running").foregroundStyle(Glance.second)
                        Text(".").foregroundStyle(Glance.need)
                    }
                    .font(Glance.a(19 * k, 700, width: 100)).tracking(-19 * k * 0.015).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: 10 * k) {
                ForEach(Glance.runners(s), id: \.id) { RunnerTile(r: $0, k: k) }
            }
        }
    }
}
