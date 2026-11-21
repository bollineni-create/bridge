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
// 1.30 = 184 pt with a two-line title: full size, lighter title weight so it isn't overbearing (Nov 21). On iPhone it would need ~1.05 to stay under 160 pt.
enum Big {
    static let k: CGFloat = 1.30
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
                RunnerBars(s: ctx.state, scale: 1.0)   // the day count lives in the expanded island now
            } compactTrailing: {
                Text(Glance.trail(ctx.state))
                    .font(ctx.state.mine > 0 ? Glance.a(13, 700) : Glance.mono(12, .semibold)).monospacedDigit()
                    .foregroundStyle(Glance.trailInk(ctx.state)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                    .background(Glance.trailFill(ctx.state))      // square red box, like the companion's RedCount
            } minimal: {
                RunnerBars(s: ctx.state, scale: 0.9)
            }
            .keylineTint(Glance.need.opacity(ctx.state.mine > 0 ? 1 : 0))
            .widgetURL(Glance.url(ctx.state))
        }
    }
}
