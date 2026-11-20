import SwiftUI
import BridgeKit

/// Command, Board and Needs you come from BridgeKit, the same parts as the iPhone Duo app, so the two look alike.
/// Like CompactScene, the only kind of file that imports BridgeKit (its Store/Runner names stay out of Bridge's own files).
struct KitPane: View {
    var which: String
    var body: some View {
        Group {
            switch which {
            case "board": DeskBoard()
            case "needs": DeskNeeds()
            default: DeskCommand()
            }
        }
        .environmentObject(BridgeKit.Store.sharedMac)
    }
}
