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
// 1.20 (Nov 21): comfortable type in the fixed-width system pill; the wide view is the big island (App/NotchPanel.swift).
enum Big {
    static let k: CGFloat = 1.20
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
                // The circle macOS gives Bridge while its own agent indicator holds the main pill (Nov 21):
                // the red count when something needs the owner, else the three runner bars.
                if ctx.state.mine > 0 {
                    Text("\(ctx.state.mine)").font(Glance.a(14, 800, width: 112)).monospacedDigit().foregroundStyle(Color.white)
                        .lineLimit(1).minimumScaleFactor(0.6).frame(width: 24, height: 24).background(Glance.need)
                } else {
                    RunnerBars(s: ctx.state, scale: 0.9)
                }
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
    var body: some View {
        if let r = Glance.current(s) {
            let id = Glance.split(Glance.task(r, s)).id
            HStack(spacing: 4) {
                Rectangle().fill(r.color).frame(width: 7, height: 7)
                Text(id.isEmpty ? r.code : id).font(Glance.mono(12.5, .bold)).foregroundStyle(Color.white)
            }
            .lineLimit(1).fixedSize()
        } else {
            HStack(spacing: 3) {
                ForEach(Glance.runners(s), id: \.id) { r in
                    Rectangle().fill(Glance.off(r.state) ? Glance.third : r.color.opacity(Glance.active(r.state) ? 1 : 0.55))
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

struct PillTrailing: View {
    let s: BridgeAttributes.ContentState
    var body: some View {
        if s.mine > 0 {
            Text("\(s.mine)").font(Glance.a(13, 800, width: 112)).monospacedDigit().foregroundStyle(Color.white)
                .lineLimit(1).fixedSize().padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20).background(Glance.need)
        } else if let r = Glance.current(s), r.state == "working", let d = r.since {
            Text(d, style: .timer).font(Glance.mono(12.5, .semibold)).monospacedDigit().foregroundStyle(Color.white)
                .lineLimit(1).frame(width: 40, alignment: .trailing)
        } else {
            Text("\(s.done)/\(Glance.total(s))").font(Glance.mono(12.5, .semibold)).monospacedDigit()
                .foregroundStyle(Glance.second).lineLimit(1).fixedSize()
        }
    }
}
