import SwiftUI
import BridgeKit

@main
struct BridgePhoneApp: App {
    init() { registerBridgeFonts() }
    var body: some Scene {
        WindowGroup { PhoneShell() }
    }
}
