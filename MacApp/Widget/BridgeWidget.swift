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
// `Big.k` scales the whole expanded island. The owner asked for it big (Nov 19). macOS fixes the island's WIDTH (about 327 pt on his
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
    // Resting pill, left (Nov 21): the runner bars, then who is working and on what ("PRO T41"); idle, today's count.
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
    // Resting pill, right: how many things wait on the owner, as one plain number (like macOS's agent pill). Clear: nothing.
    var body: some View {
        // Never empty: macOS drops the whole compact pill when one side has nothing to draw (seen Nov 21). Clear = a grey tick.
        Text(s.mine > 0 ? "\(s.mine)" : "✓")
            .font(.system(size: 14, weight: .bold)).monospacedDigit()
            .foregroundStyle(s.mine > 0 ? Color.white : Glance.second).lineLimit(1).fixedSize()
            .frame(minWidth: 20, minHeight: 20)   // a fixed slot: without it macOS dropped this side (Nov 21)
    }
}

struct PillMinimal: View {
    let s: BridgeAttributes.ContentState
    func sq(_ r: IslandRunner) -> some View {
        Rectangle().fill(Glance.off(r.state) ? Glance.third : r.color.opacity(Glance.active(r.state) ? 1 : 0.4)).frame(width: 6, height: 6)
    }
    var body: some View {
        let rs = Glance.runners(s)
        let need = s.mine > 0
        HStack(spacing: 5) {
            VStack(spacing: 2) { sq(rs[0]); sq(rs[1]); sq(rs[2]) }
            Text(need ? "\(s.mine)" : "\(s.done)")
                .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                .foregroundStyle(need ? Color.white : Glance.second)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(minWidth: 20, minHeight: 20).padding(.horizontal, need ? 3 : 0)
                .background(need ? Glance.need : Color.clear)
        }
    }
}
