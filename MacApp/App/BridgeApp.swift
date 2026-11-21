import SwiftUI
import AppKit

/// Lets code outside a view (the Dock icon, a Live Activity click, a bridge:// link) bring the main window back.
@MainActor
enum WindowOpener {
    static var open: (() -> Void)?
    static var openCompact: (() -> Void)?      // bridge://compact
    static weak var store: Store?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?      // NSApp.delegate is SwiftUI's wrapper, so views reach the real one through this
    override init() { super.init(); AppDelegate.shared = self }
    var becameActive = Date.distantPast
    var windowWasOpen = false            // was the main window on screen before this activation?
    func applicationDidBecomeActive(_ n: Notification) { becameActive = Date() }
    func applicationDidResignActive(_ n: Notification) { windowWasOpen = mainWindow != nil }
    func applicationDidFinishLaunching(_ n: Notification) { Appearance.restore(); windowWasOpen = true; NotchPanel.shared.start() }
    var mainWindow: NSWindow? { NSApp.windows.first(where: { $0.title == "Bridge" && $0.canBecomeMain && $0.isVisible }) }
    /// A link that opens another app must not leave Bridge on screen as well: put Bridge back where it was.
    func stepBack() {
        guard Date().timeIntervalSince(becameActive) < 2 else { return }      // Bridge was already in front: leave it alone
        if let w = mainWindow { if windowWasOpen { w.orderBack(nil) } else { w.close() } }
    }
    func showMain(_ pane: String? = nil) {
        if let p = pane, !p.isEmpty { WindowOpener.store?.requestedPane = p }
        if let w = NSApp.windows.first(where: { $0.title == "Bridge" && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            WindowOpener.open?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    // Clicking Bridge in the Dock, Launchpad, Spotlight or Finder while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if WindowOpener.open == nil { return true }
        showMain()
        return false
    }
    // Clicking the Live Activity, or any bridge://<pane> link.
    func application(_ application: NSApplication, open urls: [URL]) { if let u = urls.first { route(u) } }

    /// Every bridge:// link ends here, whether macOS hands it to the app or to the window.
    func route(_ u: URL) {
        var did = "main window, pane \(u.host ?? "")"
        if u.host == "compact", let o = WindowOpener.openCompact {   // the companion window
            o(); did = "compact window"
        } else if u.host == "open" {            // bridge://open/ultra | pro | local  → that runner's own app
            let who = u.lastPathComponent
            let app = who == "ultra" ? "/Applications/Claude.app" : (who == "pro" ? ClaudeApps.pro : "")
            if !app.isEmpty, let r = ClaudeApps.running(app) {           // already open: bring that account's own window forward
                stepBack()
                r.activate()
                did = "focused \(app)"
            } else if !app.isEmpty, FileManager.default.fileExists(atPath: app) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                cfg.createsNewApplicationInstance = who == "ultra"   // the Pro instance is the same Claude.app; without this macOS would only focus it
                stepBack()
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: cfg) { _, _ in
                    Task { @MainActor in self.stepBack() }
                }
                did = "opened \(app)"
            } else {
                showMain("qwen")         // Qwen lives inside Bridge
                did = "Qwen chat in Bridge"
            }
        } else if u.host == "board", let seg = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "seg" })?.value {
            KitJump.board(seg)                   // bridge://board?seg=Done|Moving|Open  → same path as the Command tiles
            showMain("board"); did = "main window, board, \(seg)"
        } else {
            showMain(u.host)
        }
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(u.absoluteString)  →  \(did)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/bridge-url.log") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: "/tmp/bridge-url.log", atomically: true, encoding: .utf8) }
    }
}

@main
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Bridge", id: "main") {
            RootView().environmentObject(store)
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)                 // design system: no title bar; the StatusStrip is the top edge
        .handlesExternalEvents(matching: [])     // links go to AppDelegate.route; they must not pop this window open

        MenuBarExtra {
            MenuPanel().environmentObject(store)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        CompactScene()
    }
}
