import WidgetKit
import SwiftUI
import ActivityKit

@main
struct BridgeWidgetBundle: WidgetBundle {
    var body: some Widget { BridgeLiveActivity() }
}

// Live Activity — Bridge design system v1 (Nov 19, 2026)
// (components LiveActivity and LiveActivityCompact). The rules it keeps:
//  - Black ground, white type. Colour appears only on the three runner badges, the three bars and one red "need you" capsule.
//  - Runners are fixed three-letter codes (ULT, PRO, MAC). Only a task title may truncate; codes, IDs, counts and times never do.
//  - Brightness is the state: working = white, holding = white title + grey status, idle / ready / offline = grey.
//  - It answers, in order: does anything need me, how far through the day are we, who holds what.
// `Big.k` scales the whole expanded island. the owner asked for it big (Nov 19). macOS fixes the island's WIDTH (about 327 pt on his
// MacBook Pro; a wider frame is clipped, tested Nov 19) and lets the HEIGHT follow the content, so big means taller and larger type.
enum Big {
    static let k: CGFloat = 1.3
}

// Glance and the island's parts live in Shared/IslandViews.swift; the app's big island panel draws the same ones.

struct BridgeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BridgeAttributes.self) { ctx in
            VStack(alignment: .leading, spacing: 9 * Big.k) {
                HStack(alignment: .center) {
                    IslandCount(s: ctx.state, k: Big.k)
                    Spacer(minLength: 8)
                    IslandNeed(s: ctx.state, k: Big.k)
                }
                IslandLanes(s: ctx.state, k: Big.k)
            }
            .padding(14)
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
                HStack(spacing: 7) {
                    RunnerBars(s: ctx.state, scale: 1.0)
                    Text("\(ctx.state.done)/\(Glance.total(ctx.state))")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color.white).lineLimit(1).fixedSize()
                }
            } compactTrailing: {
                Text(Glance.trail(ctx.state))
                    .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Glance.trailInk(ctx.state)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                    .background(Glance.trailFill(ctx.state), in: Capsule())
            } minimal: {
                RunnerBars(s: ctx.state, scale: 0.9)
            }
            .keylineTint(Glance.need.opacity(ctx.state.mine > 0 ? 1 : 0))
            .widgetURL(Glance.url(ctx.state))
        }
    }
}
