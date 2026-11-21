import SwiftUI
import BridgeKit

/// Command, Board and Needs you come from BridgeKit, the same parts as the iPhone Duo app, so the two look alike.
/// Like CompactScene, the only kind of file that imports BridgeKit (its Store/Runner names stay out of Bridge's own files).
struct KitPane: View {
    var which: String
    var open: (String) -> Void = { _ in }
    var body: some View {
        Group {
            switch which {
            case "board": DeskBoard()
            case "needs": DeskNeeds()
            default: DeskCommand(open: open)
            }
        }
        .modifier(DeskChrome())
        .environmentObject(BridgeKit.Store.sharedMac)
    }
}

/// Lets AppDelegate.route (which stays out of BridgeKit) do what a Command tile does: preselect a Board segment.
enum KitJump {
    @MainActor static func board(_ seg: String) { BridgeKit.Store.sharedMac.boardJump = seg }
}
