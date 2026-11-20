import SwiftUI

// The island's parts, shared by the Live Activity (Widget/BridgeWidget.swift) and the big island panel in the app
// (App/NotchPanel.swift). Bridge design system v1
// Every part takes one scale factor `k`; nothing here sets a width.

enum Glance {
    typealias S = BridgeAttributes.ContentState
    // Dark-theme values of the design system tokens: the island is black in light mode too.
    static let ultra = Color(red: 1.000, green: 0.624, blue: 0.039)      // runner-ultra  #FF9F0A
    static let pro = Color(red: 0.749, green: 0.353, blue: 0.949)        // runner-pro    #BF5AF2
    static let mac = Color(red: 0.251, green: 0.784, blue: 0.878)        // runner-mac    #40C8E0
    static let need = Color(red: 0.851, green: 0.176, blue: 0.145)       // critical-fill #D92D25
    static let second = Color(red: 0.631, green: 0.631, blue: 0.651)     // label-secondary #A1A1A6
    static let third = Color(red: 0.486, green: 0.486, blue: 0.502)      // label-tertiary  #7C7C80

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

/// RunnerBars: three capsules, always Ultra · Pro · This Mac. Height is the state; a grey dot is offline.
struct RunnerBars: View {
    let s: BridgeAttributes.ContentState
    var scale: CGFloat = 1
    func bar(_ state: String, _ c: Color) -> some View {
        Capsule().fill(Glance.off(state) ? Glance.third : c).frame(width: 4 * scale, height: Glance.height(state) * scale)
    }
    var body: some View {
        HStack(alignment: .center, spacing: 3 * scale) {
            bar(s.ultra, Glance.ultra); bar(s.pro, Glance.pro); bar(s.local, Glance.mac)
        }
        .frame(height: 18 * scale)
    }
}

/// RunnerBadge: the three-letter code on the runner's colour. Never dims; offline is the outline badge.
struct RunnerBadge: View {
    let code: String
    let color: Color
    var off = false
    var k: CGFloat = 1
    var body: some View {
        Text(code)
            .font(.system(size: 11 * k, weight: .bold, design: .monospaced)).tracking(0.5 * k)
            .foregroundStyle(off ? Glance.third : Color.black)
            .lineLimit(1).fixedSize()
            .frame(width: 36 * k, height: 20 * k)
            .background(off ? Color.clear : color, in: RoundedRectangle(cornerRadius: 6 * k, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6 * k, style: .continuous).strokeBorder(off ? Glance.third : Color.clear, lineWidth: 1.5 * k))
    }
}

/// ProgressSpan: thick where the day has been, a node where we are, thin to the far anchor. One colour, no gradient.
struct ProgressSpan: View {
    let value: Double
    var k: CGFloat = 1
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let node = 12 * k
            let x = max(node / 2, min(w - node / 2, w * value))
            ZStack(alignment: .leading) {
                Capsule().fill(Glance.third).frame(width: w, height: 2 * k)
                Circle().fill(Glance.third).frame(width: 6 * k, height: 6 * k).offset(x: w - 6 * k)
                Capsule().fill(Color.white).frame(width: x, height: 6 * k)
                Circle().fill(Color.black).frame(width: node + 6 * k, height: node + 6 * k).offset(x: x - node / 2 - 3 * k)
                Circle().fill(Color.white).frame(width: node, height: node).offset(x: x - node / 2)
            }
            .frame(width: w, height: g.size.height, alignment: .leading)
        }
        .frame(height: 12 * k)
    }
}

/// One runner: code, task ID, title, then elapsed time (working) or the state word.
struct Lane: View {
    let id: String
    let code: String
    let color: Color
    let state: String
    let on: String
    let since: Date?
    var k: CGFloat = 1
    var body: some View {
        let t = Glance.split(on)
        let named = !on.isEmpty
        let title = t.title.isEmpty ? (t.id.isEmpty ? Glance.word(state) : t.id) : t.title
        let quiet = !Glance.active(state)
        Link(destination: URL(string: "bridge://open/" + id)!) {
            HStack(spacing: 8 * k) {
                RunnerBadge(code: code, color: color, off: Glance.off(state), k: k)
                if !t.id.isEmpty && !t.title.isEmpty {
                    Text(t.id).font(.system(size: 13 * k, weight: .medium, design: .monospaced)).foregroundStyle(Glance.second).lineLimit(1).fixedSize()
                }
                Text(title).font(.system(size: 13 * k, weight: quiet ? .regular : .medium)).foregroundStyle(quiet ? Glance.second : Color.white)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4 * k)
                if state == "working", let d = since {
                    // A timer Text asks for all the width there is, so it gets a fixed slot: m:ss under an hour, h:mm:ss after.
                    Text(d, style: .timer).font(.system(size: 13 * k, weight: .semibold)).monospacedDigit().foregroundStyle(Color.white)
                        .multilineTextAlignment(.trailing).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: (Date().timeIntervalSince(d) < 3540 ? 40 : 58) * k, alignment: .trailing)
                } else {
                    Text(named ? Glance.word(state) : "").font(.system(size: 13 * k, weight: state == "working" ? .semibold : .regular))
                        .foregroundStyle(state == "working" ? Color.white : Glance.second).lineLimit(1).fixedSize()
                }
            }
            .frame(height: 20 * k)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Left of the camera: the bars and today's count.
struct IslandCount: View {
    let s: BridgeAttributes.ContentState
    var k: CGFloat = 1
    func row(_ caption: String) -> some View {
        HStack(alignment: .center, spacing: 9 * k) {
            RunnerBars(s: s, scale: 1.45 * k)
            HStack(alignment: .firstTextBaseline, spacing: 5 * k) {
                Text("\(s.done)").font(.system(size: 28 * k, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Color.white)
                Text(caption).font(.system(size: 13 * k, weight: .medium)).foregroundStyle(Glance.second)
            }
            .lineLimit(1).fixedSize()
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row("of \(Glance.total(s)) done today")
            row("of \(Glance.total(s))")
            row("")
        }
    }
}

/// Right of the camera: the one alarm on the island, or "All clear".
struct IslandNeed: View {
    let s: BridgeAttributes.ContentState
    var k: CGFloat = 1
    func capsule(_ words: String) -> some View {
        HStack(spacing: 5 * k) {
            Text("\(s.mine)").font(.system(size: 13 * k, weight: .bold, design: .rounded)).monospacedDigit()
            Text(words).font(.system(size: 13 * k, weight: .semibold))
        }
        .foregroundStyle(Color.white).lineLimit(1).fixedSize()
        .padding(.horizontal, 10 * k).frame(height: 26 * k)
        .background(Glance.need, in: Capsule())
    }
    var body: some View {
        if s.mine > 0 {
            ViewThatFits(in: .horizontal) {
                capsule(s.mine == 1 ? "needs you" : "need you")
                Text("\(s.mine)").font(.system(size: 13 * k, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Color.white)
                    .fixedSize().padding(.horizontal, 7 * k).frame(minWidth: 26 * k, minHeight: 26 * k).background(Glance.need, in: Capsule())
            }
        } else {
            Text("All clear").font(.system(size: 13 * k, weight: .medium)).foregroundStyle(Glance.second).lineLimit(1).fixedSize()
        }
    }
}

/// Below the camera: the progress line and one lane per runner.
struct IslandLanes: View {
    let s: BridgeAttributes.ContentState
    var k: CGFloat = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressSpan(value: Glance.progress(s), k: k).padding(.bottom, 9 * k)
            VStack(alignment: .leading, spacing: 5 * k) {
                Lane(id: "ultra", code: "ULT", color: Glance.ultra, state: s.ultra, on: s.ultraOn, since: s.ultraSince, k: k)
                Lane(id: "pro", code: "PRO", color: Glance.pro, state: s.pro, on: s.proOn, since: s.proSince, k: k)
                Lane(id: "local", code: "MAC", color: Glance.mac, state: s.local, on: s.localOn, since: s.localSince, k: k)
            }
        }
    }
}
