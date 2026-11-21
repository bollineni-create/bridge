import WidgetKit
import SwiftUI
import ActivityKit

@main
struct BridgeWidgetBundle: WidgetBundle {
    var body: some Widget { BridgeLiveActivity() }
}

// Live Activity in Swiss Tombstone, night room (Nov 20, 2026): the same system as Bridge.app and the companion.
//  - Black ground, white ink, one red. Square corners. Archivo for words and figures, SF Mono for codes and IDs.
//  - Runner tint only while that runner works or holds; everything else is grey.
//  - Runners are fixed three-letter codes (ULT, PRO, MAC). Only a task title may truncate; codes, IDs, counts and times never do.
//  - Layout A (Nov 20): small day count, the task at hand as the hero, three runner tiles in their colours.
// `Big.k` scales the whole expanded island. the owner asked for it big (Nov 19). macOS fixes the island's WIDTH (about 327 pt on his
// MacBook Pro; a wider frame is clipped, tested Nov 19) and lets the HEIGHT follow the content, so big means taller and larger type.
// Nov 21: macOS draws the island as tall as its content (seen at ~190 pt, nothing clipped); Apple's 160 pt cap is the iPhone's.
// 1.25 = 152 pt with design C (Nov 21). macOS SHRINKS the whole island when content passes ~160 pt (seen on his Mac), so the title is one line and k stays under that.
enum Big {
    static let k: CGFloat = 1.25
}

// Glance and the island's parts live in Shared/IslandViews.swift; the app's big island panel draws the same ones.

struct BridgeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BridgeAttributes.self) { ctx in
            VStack(alignment: .leading, spacing: 8 * Big.k) {
                HStack(alignment: .center) {
                    IslandCount(s: ctx.state, k: Big.k)
                    Spacer(minLength: 8)
                    IslandNeed(s: ctx.state, k: Big.k)
                }
                IslandLanes(s: ctx.state, k: Big.k)
            }
            .padding(14)
            .overlay(alignment: .top) { Rectangle().fill(Color.white).frame(height: 2) }   // the site's 2px rule, inverted for night
            .activityBackgroundTint(Color.black)
            .widgetURL(Glance.url(ctx.state))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    IslandCount(s: ctx.state, k: Big.k).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandNeed(s: ctx.state, k: Big.k).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandLanes(s: ctx.state, k: Big.k)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 6)
                }
            } compactLeading: {
                PillLeading(s: ctx.state)
            } compactTrailing: {
                PillTrailing(s: ctx.state)
            } minimal: {
                // Bridge's slot while macOS's agent indicator holds the island (Nov 21). One fixed tree (no if/else):
                // three runner squares (lit = working/holding), then the red count of things waiting on the owner.
                PillMinimal(s: ctx.state)
            }
            .keylineTint(Glance.need.opacity(ctx.state.mine > 0 ? 1 : 0))
            .widgetURL(Glance.url(ctx.state))
        }
    }
}

// The resting pill (Nov 21): enough to read without holding it.
// Left: who is working and on what ("PRO T41"); with nothing running, three squares in the runners' colours.
// Right: the red count when something needs the owner, else the running timer, else today's count.
struct PillLeading: View {
    let s: BridgeAttributes.ContentState
    // Resting pill, left: who is working and on what ("PRO T41"); idle, today's count.
    // One fixed tree with computed strings and colours: on macOS the compact pill draws blank with if/else or ForEach.
    var body: some View {
        let r = Glance.current(s)
        let id = r.map { Glance.split(Glance.task($0, s)).id } ?? ""
        // The compact side slot is narrow on macOS: wider content and the whole pill draws blank (Nov 21). Keep it ~40 pt.
        let label = r.map { id.isEmpty ? $0.code : id } ?? "\(s.done)"
        HStack(spacing: 4) {
            Rectangle().fill(r?.color ?? Glance.third).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(r?.color ?? Glance.second).lineLimit(1).fixedSize()
        }
    }
}

struct PillTrailing: View {
    let s: BridgeAttributes.ContentState
    // Resting pill, right (Nov 21): the same progress disc as the round slot. While an agent is active macOS replaces the
    // left half with its own icon and this is all of Bridge that shows, so the two layouts must read the same.
    var body: some View { PillMinimal(s: s) }
}

/// The round slot and the pill's right half (Nov 21, option C "Ring", chosen by the owner). A thin ring rises from the bottom
/// up both sides and meets at the top as the current task progresses (s.focusPct: the runner's reported % or an
/// elapsed-time estimate that stops at 95%), in the working runner's colour on a dark track. In the middle, the account
/// that is working (U / P / M in its colour; a grey dot when idle). Done: the ring closes with a white tick for 12 s.
/// Fixed tree: only trim amounts and colours vary (macOS blanks the slot otherwise).
struct PillMinimal: View {
    let s: BridgeAttributes.ContentState
    var body: some View {
        let flash = !s.justDone.isEmpty
        let p = CGFloat(flash ? 1 : min(max(s.focusPct, 0), 1))
        let tint = Glance.current(s)?.color ?? Glance.second
        let half = p / 2
        let r = Glance.current(s)
        // Centre: who is working (U / P / M in that account's colour); idle: a grey dot; done: a white tick.
        let mark = flash ? "✓" : (r.map { String(Glance.name($0.id).prefix(1)) } ?? "•")
        Text(mark)
            .font(.system(size: flash ? 12 : 12.5, weight: .heavy, design: .rounded))
            .foregroundStyle(flash ? Color.white : (r?.color ?? Glance.third))
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(width: 26, height: 26)
            // No rotation, no overlay (with those the whole Live Activity drew blank, Nov 21). SwiftUI's trim starts at
            // 3 o'clock and runs clockwise, so the bottom is 0.25: the left arc climbs 0.25 → 0.75, the right arc climbs
            // 0.25 → 0 and wraps 1 → 0.75. Three fixed trims, only their amounts vary.
            .background {
                ZStack {
                    Circle().stroke(Glance.line, lineWidth: 2.5)
                    Circle().trim(from: 0.25, to: 0.25 + half).stroke(tint, lineWidth: 2.5)
                    Circle().trim(from: max(0, 0.25 - half), to: 0.25).stroke(tint, lineWidth: 2.5)
                    Circle().trim(from: 1 - max(0, half - 0.25), to: 1).stroke(tint, lineWidth: 2.5)
                }
                .animation(.linear(duration: 2), value: half)
                .padding(1.25)
            }
    }
}
