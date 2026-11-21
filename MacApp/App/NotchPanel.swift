import SwiftUI
import AppKit

// The big island (Nov 19, 2026). macOS fixes the system Live Activity at about 330 pt wide on this MacBook Pro, so the size the owner
// drew lives here: a borderless panel that drops from the camera when the pointer rests on the Live Activity at the top centre of
// the display, and folds away when the pointer leaves. It draws the same parts as the Live Activity (Shared/IslandViews.swift) at a
// larger scale, so the two can never look different. The system Live Activity stays as the small resting pill.
//  - Size: `NotchPanel.width` and `NotchPanel.k`. Height follows the content.
//  - Off switch: `bridge config big_island 0`. It also goes away when the Live Activity is switched off.
//  - It never activates Bridge. A lane opens that runner's own app through AppDelegate.route, the same as the Live Activity.

@MainActor
final class NotchModel: ObservableObject {
    @Published var state: BridgeAttributes.ContentState?
    @Published var open = false
}

final class FirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    let top: CGFloat          // height of the camera housing: the count and the alarm sit either side of it, like the Live Activity
    let camera: CGFloat       // width of the camera housing
    var body: some View {
        let k = NotchPanel.k
        VStack(alignment: .leading, spacing: 8 * k) {
            if let s = model.state {
                HStack(alignment: .center, spacing: 0) {
                    Link(destination: URL(string: "bridge://command")!) { IslandCount(s: s, k: k).contentShape(Rectangle()) }.buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: camera + 24, height: 1)
                    Link(destination: URL(string: "bridge://needs")!) { IslandNeed(s: s, k: k).contentShape(Rectangle()) }.buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: max(top, 34 * k))
                IslandLanes(s: s, k: k)
            }
        }
        // Nov 20, 2026: same design as the small Live Activity (floating, all four corners round, a small gap above),
        // only at NotchPanel.width / NotchPanel.k.
        .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 20)
        .frame(width: NotchPanel.width, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .padding(.top, NotchPanel.inset)
        .opacity(model.open ? 1 : 0)
        .scaleEffect(x: model.open ? 1 : 0.4, y: model.open ? 1 : 0.15, anchor: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.open)
        .environment(\.colorScheme, .dark)
        .environment(\.openURL, OpenURLAction { url in
            NotchPanel.shared.close()
            AppDelegate.shared?.route(url)
            return .handled
        })
    }
}

@MainActor
final class NotchPanel {
    static let shared = NotchPanel()
    static let width: CGFloat = 660   // Nov 21: twice the system Live Activity (~330 pt), type kept comfortable
    static let k: CGFloat = 1.25
    static let inset: CGFloat = 5          // gap above the panel, like the small island
    let model = NotchModel()
    var enabled = false      // off: macOS draws its own expanded island above every window, so a second panel always stacks
    private var panel: NSPanel?
    private var timer: Timer?
    private var outside = 0
    private var pinnedUntil = Date.distantPast
    // Intent (Nov 19, 2026): the owner wants the big view only when he means it; a pass across the top leaves the Live Activity alone.
    private var trail: [(t: Date, p: CGPoint)] = []      // the last second of pointer positions
    private var restStart: Date?                          // when the pointer settled on the Live Activity
    private var armed = true                              // after the island closes, the pointer must leave the pill before it can open again
    private var scrollMonitor: Any?
    static let dwell: TimeInterval = 0.45                 // how long the pointer must rest on the pill
    static let still: CGFloat = 70                        // pt per second: slower than this counts as resting

    /// The display with the camera; the one with the menu bar otherwise.
    private var screen: NSScreen? { NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first }
    private func top(_ s: NSScreen) -> CGFloat { max(s.safeAreaInsets.top, s.frame.maxY - s.visibleFrame.maxY, 28) }

    func feed(_ st: BridgeAttributes.ContentState?, enabled on: Bool) {
        enabled = on
        if model.state != st { model.state = st }
        if (st == nil || !on) && model.open { close() }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in Task { @MainActor in NotchPanel.shared.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Two-finger swipe down (or wheel down) on the pill opens the big view at once, like pulling the island down.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { e in
            let dy = e.scrollingDeltaY, momentum = !e.momentumPhase.isEmpty
            Task { @MainActor in NotchPanel.shared.pulled(dy, momentum: momentum) }
        }
    }

    /// The Live Activity pill itself: the camera housing plus the pill's flanks, menu-bar height. Not the whole top of the screen.
    private func pill(_ s: NSScreen) -> CGRect {
        let h = top(s)
        let left = s.auxiliaryTopLeftArea?.width ?? 0, right = s.auxiliaryTopRightArea?.width ?? 0
        let camera = (left > 0 && right > 0) ? max(0, s.frame.width - left - right) : 0
        let half = max(camera / 2 + 62, 80)
        return CGRect(x: s.frame.midX - half, y: s.frame.maxY - h, width: half * 2, height: h + 2)
    }

    /// Something else at the top of the screen has his attention: an open menu, Spotlight, typing, a drag.
    private func busy() -> Bool {
        if NSEvent.pressedMouseButtons != 0 { return true }
        if NSApp.currentSystemPresentationOptions.contains(.fullScreen) { return true }
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < 1.2 { return true }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) { return true }          // a menu is open
            if owner == "Spotlight" || owner == "Notification Center" { return true }
        }
        return false
    }

    private func pulled(_ dy: CGFloat, momentum: Bool) {
        guard !model.open, !momentum, dy < -2, enabled, model.state != nil, let s = screen else { return }
        guard pill(s).insetBy(dx: -10, dy: -4).contains(NSEvent.mouseLocation), !busy() else { return }
        open()
    }

    /// Ten times a second. Opens only when the pointer comes to rest on the pill for `dwell`; a pass on the way to a menu,
    /// Spotlight or another app does nothing, and the normal Live Activity stays as it is.
    private func poll() {
        guard let s = screen else { return }
        let p = NSEvent.mouseLocation
        let now = Date()
        if model.open {
            guard now > pinnedUntil, let f = panel?.frame else { return }
            outside = f.insetBy(dx: -14, dy: -14).contains(p) ? 0 : outside + 1
            if outside >= 4 { close() }
            return
        }
        trail.append((now, p))
        trail.removeAll { now.timeIntervalSince($0.t) > 1.0 }
        let zone = pill(s)
        guard zone.contains(p) else { restStart = nil; armed = true; return }
        guard armed, enabled, model.state != nil, !busy() else { restStart = nil; return }
        // Speed over the last 0.3 s: still means he stopped on it, fast means he is passing through.
        let recent = trail.filter { now.timeIntervalSince($0.t) <= 0.3 }
        var speed: CGFloat = 0
        if let first = recent.first, recent.count >= 2 {
            let dt = max(now.timeIntervalSince(first.t), 0.05)
            speed = hypot(p.x - first.p.x, p.y - first.p.y) / CGFloat(dt)
        }
        if speed > Self.still { restStart = nil; return }
        if restStart == nil { restStart = now }
        if now.timeIntervalSince(restStart!) >= Self.dwell { open() }
    }

    func open(pin seconds: Double = 0) {
        guard let s = screen, model.state != nil else { return }
        if seconds > 0 { pinnedUntil = Date().addingTimeInterval(seconds) }
        let left = s.auxiliaryTopLeftArea?.width ?? 0, right = s.auxiliaryTopRightArea?.width ?? 0
        let camera = (left > 0 && right > 0) ? max(0, s.frame.width - left - right) : 0
        let view = NotchView(model: model, top: max(s.safeAreaInsets.top, 28), camera: camera)
        let p = panel ?? make()
        let host = FirstMouseHost(rootView: view)
        let size = host.fittingSize
        p.contentView = host
        p.setFrame(CGRect(x: (s.frame.midX - size.width / 2).rounded(), y: s.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        outside = 0; restStart = nil; armed = false
        DispatchQueue.main.async { self.model.open = true }
    }

    func close() {
        guard model.open else { return }
        model.open = false
        pinnedUntil = .distantPast
        outside = 0; restStart = nil
        armed = !pill(screen ?? NSScreen.main!).contains(NSEvent.mouseLocation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { if !self.model.open { self.panel?.orderOut(nil) } }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Above everything, including macOS's own expanded Live Activity, so the two never show stacked.
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        panel = p
        return p
    }
}
