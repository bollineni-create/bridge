import SwiftUI
import BridgeKit

/// Bridge's compact window: the same companion the iPhone Duo runs, in bollineni.co's Swiss Tombstone style.
/// The only file that imports BridgeKit, so its Store/Runner names never meet Bridge's own.
struct CompactScene: Scene {
    @ObservedObject private var store = BridgeKit.Store.sharedMac
    init() { registerBridgeFonts() }
    var body: some Scene {
        Window("Bridge Compact", id: "compact") {
            CompanionRoot().environmentObject(store)
                .frame(minWidth: 380, idealWidth: 420, minHeight: 560, idealHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 420, height: 760)
        .defaultPosition(.topTrailing)
        .commands {
            CommandGroup(after: .windowArrangement) { OpenCompact() }
        }
    }
}

/// Window menu item and shortcut: Compact View  ⌘⇧K
struct OpenCompact: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Compact View") { openWindow(id: "compact") }.keyboardShortcut("k", modifiers: [.command, .shift])
    }
}
