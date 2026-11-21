import SwiftUI
import AppKit
import ActivityKit
import EventKit

let bridgePy = NSHomeDirectory() + "/Claude/bridge/bridge.py"
let snapshotPath = NSHomeDirectory() + "/Library/Application Support/Bridge/snapshot.json"

/// Every change goes through the engine's command line, so the app, both Claude accounts and Qwen all write the same way.
func runBridge(_ args: [String], stdin: String? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = [bridgePy] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    let inp = Pipe()
    if stdin != nil { p.standardInput = inp }
    do { try p.run() } catch { return (-1, "could not start the engine: \(error.localizedDescription)") }
    if let s = stdin, let d = s.data(using: .utf8) {
        inp.fileHandleForWriting.write(d)
        try? inp.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
}

func bg<T>(_ f: @escaping () -> T) async -> T {
    await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: f()) } }
}

@MainActor final class Store: ObservableObject {
    @Published var snap: Snapshot?
    @Published var engineLive = false
    @Published var toast = ""
    @Published var activityOn = false
    @Published var decodeError = ""
    let kit = Kit()
    let locator = Locator()
    let vault = Vault()
    let perms = Permissions()
    let qwen = QwenChat()

    private var mtime: Date?
    private var ticks = 0
    private var running = Set<Int>()
    private var notified = Set<String>()
    private var primed = false
    private var lastKick = Date.distantPast
    private var activity: Activity<BridgeAttributes>?
    private var lastKey = ""
    private var lastRequest = Date.distantPast

    init() {
        // Nov 21 (N28): never end the Live Activity at launch. Ending it gave up Bridge's island slot on every relaunch, and a
        // new one can only be requested while Bridge is frontmost. updateActivity() adopts the surviving activity, ends extras
        // and pushes fresh state on the first snapshot, so a stale pill lasts about a second instead of losing the slot.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Task { @MainActor in self.tick() } }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: kit.store, queue: .main) { _ in Task { @MainActor in await self.pushKit() } }
        Task {
            await kit.request()
            await pushKit()
            Notifier.request()
            locator.start { json in DispatchQueue.global().async { _ = runBridge(["ingest", "location"], stdin: json) } }
        }
        tick()
    }

    // MARK: snapshot
    var probing = false
    var sweeping = false
    var chatSeen: [String: Date] = [:]
    /// While he is away from the Mac, open each recent chat in Claude (Ultra) and Claude Pro in turn, read it, and put back the chat he left open.
    /// That way Bridge knows every conversation, not only the one on screen.
    func sweepChats() {
        sweeping = true
        DispatchQueue.global(qos: .utility).async {
            for (who, path) in [("ultra", "/Applications/Claude.app"), ("pro", ClaudeApps.pro)] {
                guard let first = AppProbe.chatRead(path, maxChars: 1000), (first["window"] as? Bool) == true else { continue }
                if (first["generating"] as? Bool) == true { continue }
                if ClaudeApps.isFront(path) { continue }
                let original = first["open"] as? String ?? ""
                var n = 0
                for title in (first["recents"] as? [String]) ?? [] {
                    if n >= 8 || AppProbe.idleSeconds() < 200 { break }
                    let key = who + ":" + title
                    if let t = self.chatSeenGet(key), Date().timeIntervalSince(t) < 1800 { continue }
                    guard AppProbe.focusChat(path, title) == title, let got = AppProbe.chatRead(path) else { continue }
                    self.chatSeenSet(key)
                    if let d = try? JSONSerialization.data(withJSONObject: [who: got]), let j = String(data: d, encoding: .utf8) { _ = runBridge(["probe", "--sweep"], stdin: j) }
                    n += 1
                }
                if !original.isEmpty { _ = AppProbe.focusChat(path, original) }
            }
            Task { @MainActor in self.sweeping = false }
        }
    }
    nonisolated func chatSeenGet(_ k: String) -> Date? { DispatchQueue.main.sync { MainActor.assumeIsolated { self.chatSeen[k] } } }
    nonisolated func chatSeenSet(_ k: String) { DispatchQueue.main.async { MainActor.assumeIsolated { self.chatSeen[k] = Date() } } }
    var probeNow = true
    var lastProbe = Date.distantPast
    var lastHot: [Bool] = []
    var hotFlip: Date?
    func tick() {
        ticks += 1
        if NSApp.isActive || ticks % 3 == 0 || ticks < 5 { load() }      // the snapshot is ~0.7 MB; in the background read it every 3 s, not every second
        // Nov 21: the progress ring moves with time, not only when the board changes. Every 2 s re-run the island update;
        // it only pushes to the Live Activity when the ring has moved a step (1%), so a still island costs nothing.
        if ticks % 2 == 0, activity != nil { updateActivity() }
        if let g = snap?.generated { engineLive = Date().timeIntervalSince1970 - g < 12 } else { engineLive = false }
        if !engineLive && Date().timeIntervalSince(lastKick) > 45 {
            lastKick = Date()
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["kickstart", "gui/\(getuid())/com.naren.bridge.engine"]
                try? p.run()
            }
        }
        selfCheck()
        if FileManager.default.fileExists(atPath: "/tmp/bridge-probe-now") { try? FileManager.default.removeItem(atPath: "/tmp/bridge-probe-now"); probeNow = true }   // Bridge Chat waits on a Claude reply
        if ticks % 60 == 0 && !sweeping && snap?.settings["read_windows"] != "0" && AppProbe.idleSeconds() > 240 { sweepChats() }
        // Reading another app's window makes macOS show its own "Bridge is accessing…" pill, which squeezes the Live Activity.
        // So: read every 4 s only while Bridge itself is in front; otherwise read when a Claude app starts or stops working
        // (CPU flips), and as a slow refresh.
        let slow = snap?.settings["read_windows"] == "0" ? 0 : (Double(snap?.settings["probe_secs"] ?? "300") ?? 300)
        var due = false
        if slow > 0 && !probing {
            let hot = (snap?.runners ?? []).filter { $0.id != "local" }.map { ($0.cpu ?? 0) >= 10 }
            if hot != lastHot { lastHot = hot; hotFlip = Date() }
            let sinceProbe = Date().timeIntervalSince(lastProbe)
            if NSApp.isActive { due = ticks % 4 == 0 }
            else if sinceProbe > slow { due = true }
            else if let f = hotFlip, Date().timeIntervalSince(f) > 4, f > lastProbe, sinceProbe > 120 { due = true }
            if probeNow { due = true; probeNow = false }
        }
        if due {
            lastProbe = Date()
            probing = true
            DispatchQueue.global(qos: .utility).async {
                var out: [String: Any] = [:]
                if let u = AppProbe.chatReadSettled("/Applications/Claude.app") { out["ultra"] = u }
                if let p = AppProbe.chatReadSettled(ClaudeApps.pro) { out["pro"] = p }
                if !out.isEmpty, let d = try? JSONSerialization.data(withJSONObject: out), let j = String(data: d, encoding: .utf8) { _ = runBridge(["probe"], stdin: j) }
                Task { @MainActor in self.probing = false }
            }
        }
        if ticks % 60 == 0 { Task { await pushKit() } }
        if ticks % 60 == 30, !locator.last.isEmpty { let j = locator.last; DispatchQueue.global().async { _ = runBridge(["ingest", "location"], stdin: j) } }
        if ticks % 6 == 0, snap?.settings["music_on"] != "0" { DispatchQueue.global().async { _ = runBridge(["music-sync"]) } }
    }

    func load() {
        let url = URL(fileURLWithPath: snapshotPath)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: snapshotPath), let m = attrs[.modificationDate] as? Date else { return }
        if m == mtime { return }
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            snap = try JSONDecoder().decode(Snapshot.self, from: data)
            mtime = m
            decodeError = ""
            runActions()
            notifyNew()
            updateActivity()
        } catch {
            decodeError = "\(error)"
        }
    }

    // MARK: self-check. A runner writes a pane name to /tmp/bridge-ui-request; the app shows that pane and saves a picture of its own
    // window to /tmp/bridge-ui-<pane>.png. It photographs only itself, so it needs no screen-recording permission.
    var requestedPane: String = "" { didSet { if !requestedPane.isEmpty { paneTick += 1 } } }
    @Published var paneTick = 0
    func selfCheck() {
        let req = "/tmp/bridge-ui-request"
        guard let name = try? String(contentsOfFile: req, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: req)
        if name == "grant-accessibility" { askAccessibility(); return }
        if name == "perms" { perms.refresh(); return }
        if name.hasPrefix("focus-chat:") {   // engine hook: focus-chat:<ultra|pro>:<title>  → /tmp/bridge-focus.txt
            let parts = name.dropFirst(11).split(separator: ":", maxSplits: 1).map(String.init)
            let path = parts.first == "pro" ? ClaudeApps.pro : "/Applications/Claude.app"
            let title = parts.count > 1 ? parts[1] : ""
            DispatchQueue.global().async { try? AppProbe.focusChat(path, title).write(toFile: "/tmp/bridge-focus.txt", atomically: true, encoding: .utf8) }
            return
        }
        if name.hasPrefix("send-check:") {   // engine hook: did the message Bridge just typed really send?  → /tmp/bridge-send-<who>.txt
            let who = String(name.dropFirst(11))
            let path = who == "pro" ? ClaudeApps.pro : "/Applications/Claude.app"
            DispatchQueue.global().async {
                if let d = try? JSONSerialization.data(withJSONObject: AppProbe.sendState(path)) { try? d.write(to: URL(fileURLWithPath: "/tmp/bridge-send-\(who).txt"), options: .atomic) }
            }
            return
        }
        if name.hasPrefix("ax-post:") {      // engine hook: ax-post:<who>:<request.json> → <request>.result (send without taking focus)
            let parts = name.dropFirst(8).split(separator: ":", maxSplits: 1).map(String.init)
            let path = parts.first == "pro" ? ClaudeApps.pro : "/Applications/Claude.app"
            let file = parts.count > 1 ? parts[1] : ""
            DispatchQueue.global().async {
                var res = "fail: bad request"
                if let d = FileManager.default.contents(atPath: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    res = AppProbe.post(path, text: j["text"] as? String ?? "", newChat: j["new"] as? Bool ?? true, chat: j["chat"] as? String ?? "",
                                        model: j["model"] as? String ?? "", effort: j["effort"] as? String ?? "")
                }
                try? res.write(toFile: file + ".result", atomically: true, encoding: .utf8)
            }
            return
        }
        if name.hasPrefix("ax-model:") {     // hook: ax-model:<who>:<Model name>:<effort> → /tmp/bridge-model-<who>.txt
            let parts = name.dropFirst(9).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let path = parts.first == "pro" ? ClaudeApps.pro : "/Applications/Claude.app"
            DispatchQueue.global().async {
                let r = AppProbe.setModel(path, model: parts.count > 1 ? parts[1] : "", effort: parts.count > 2 ? parts[2] : "")
                try? r.write(toFile: "/tmp/bridge-model-\(parts.first ?? "x").txt", atomically: true, encoding: .utf8)
            }
            return
        }
        if name.hasPrefix("ax-menu:") {      // test hook: what the model picker offers  → /tmp/bridge-axmenu-<who>.txt
            let who = String(name.dropFirst(8))
            let path = who == "pro" ? ClaudeApps.pro : "/Applications/Claude.app"
            DispatchQueue.global().async { try? AppProbe.modelMenuDump(path).write(toFile: "/tmp/bridge-axmenu-\(who).txt", atomically: true, encoding: .utf8) }
            return
        }
        if name.hasPrefix("ax-dump:") {      // test hook: structure of a runner app's window
            let who = String(name.dropFirst(8))
            let path = who == "pro" ? ClaudeApps.pro : "/Applications/Claude.app"
            DispatchQueue.global().async { try? AppProbe.dump(path).write(toFile: "/tmp/bridge-ax-\(who).txt", atomically: true, encoding: .utf8) }
            return
        }
        if name.hasPrefix("qwen:") {         // test hook: ask Qwen in the chat pane
            requestedPane = "qwen"
            qwen.send(String(name.dropFirst(5)), model: snap?.settings["model"] ?? "qwen3.8:27b-mlx")
            return
        }
        if name.hasPrefix("appearance:") {   // test hook: force light or dark for this app only
            let v = String(name.dropFirst(11))
            Appearance.set(v == "dark" || v == "light" ? v : "auto")   // same path as Settings, so the picker stays in sync
            return
        }
        if name.hasPrefix("click:") {        // test hook: one left click at x,y (points, top-left origin); needs Accessibility
            let p = name.dropFirst(6).split(separator: ",").compactMap { Double($0) }
            if p.count == 2 {
                let pt = CGPoint(x: p[0], y: p[1])
                for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            }
            return
        }
        if name == "views" {                 // test hook: dump the main window's NSView tree (scroll views: document size, clip bounds) to /tmp/bridge-views.txt
            var out = ""
            func walk(_ v: NSView, _ d: Int) {
                var extra = ""
                if let sv = v as? NSScrollView { extra = " SCROLL doc=\(sv.documentView?.frame ?? .zero) clipBounds=\(sv.contentView.bounds) vScroller=\(sv.hasVerticalScroller)" }
                out += String(repeating: " ", count: d) + String(describing: type(of: v)) + " \(v.frame)" + (v.isHidden ? " HIDDEN" : "") + extra + "\n"
                for c in v.subviews { walk(c, d + 1) }
            }
            if let w = NSApp.windows.first(where: { $0.title == "Bridge" && $0.contentView != nil }), let v = w.contentView { walk(v, 0) }
            try? out.write(toFile: "/tmp/bridge-views.txt", atomically: true, encoding: .utf8)
            return
        }
        if name.hasPrefix("hit:") {          // test hook: hit:x,y (window points, top-left origin) -> which view takes the event; then wheel events sent straight to the biggest scroll view under it -> /tmp/bridge-hit.txt
            let p = name.dropFirst(4).split(separator: ",").compactMap { Double($0) }
            var out = ""
            if p.count >= 2, let w = NSApp.windows.first(where: { $0.title == "Bridge" && $0.contentView != nil }), let cv = w.contentView {
                let pt = NSPoint(x: p[0], y: cv.isFlipped ? p[1] : cv.bounds.height - p[1])
                let hit = cv.hitTest(cv.superview.map { cv.convert(pt, to: $0) } ?? pt)
                out += "window=\(w.frame) content=\(cv.frame)\nhit chain:\n"
                var v: NSView? = hit; var sv: NSScrollView?
                while let x = v { out += "  " + String(describing: type(of: x)) + " \(x.frame)\n"; if sv == nil, let s = x as? NSScrollView { sv = s }; v = x.superview }
                if let s = sv {
                    out += "scroll view: doc=\(s.documentView?.frame ?? .zero) clip=\(s.contentView.bounds) before\n"
                    let before = s.contentView.bounds.origin.y
                    func send(_ phase: Int64, _ dy: Int32) {
                        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
                        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                        if let ev = NSEvent(cgEvent: cg) { s.scrollWheel(with: ev); out += "  sent phase \(phase) dy \(dy) -> NSEvent phase \(ev.phase.rawValue) scrollingDeltaY \(ev.scrollingDeltaY) origin \(s.contentView.bounds.origin.y)\n" }
                    }
                    send(1, 0); for _ in 0..<6 { send(2, -40) }; send(4, 0)
                    out += "clip origin y: \(before) -> \(s.contentView.bounds.origin.y); scrollEnabled? verticalScrollElasticity=\(s.verticalScrollElasticity.rawValue) usesPredominantAxis=\(s.usesPredominantAxisScrolling) hasV=\(s.hasVerticalScroller)\n"
                    s.contentView.scroll(to: NSPoint(x: 0, y: 120)); s.reflectScrolledClipView(s.contentView)
                    out += "after programmatic scroll(to: 120): \(s.contentView.bounds.origin.y)\n"
                } else { out += "no NSScrollView in hit chain\n" }
            }
            try? out.write(toFile: "/tmp/bridge-hit.txt", atomically: true, encoding: .utf8)
            return
        }
        if name == "evlog" {                 // test hook: log every scroll-wheel event this app receives (window point, phase, view hit, detail scroll offset after) to /tmp/bridge-events.txt for 60 s
            try? "".write(toFile: "/tmp/bridge-events.txt", atomically: true, encoding: .utf8)
            let mon = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                var line = "t=\(String(format: "%.2f", e.timestamp)) phase=\(e.phase.rawValue) mom=\(e.momentumPhase.rawValue) dy=\(e.scrollingDeltaY) win=\(e.window?.title ?? "nil") loc=\(e.locationInWindow)"
                if let cv = e.window?.contentView, let h = cv.hitTest(cv.superview.map { cv.convert(e.locationInWindow, to: $0) } ?? e.locationInWindow) {
                    var v: NSView? = h; var chain: [String] = []; var sv: NSScrollView?
                    while let x = v { if chain.count < 3 { chain.append(String(describing: type(of: x)).prefix(28).description) }; if sv == nil, let s = x as? NSScrollView { sv = s }; v = x.superview }
                    line += " hit=\(chain.joined(separator: ">")) scrollDoc=\(sv?.documentView?.frame.height ?? -1) origin=\(sv?.contentView.bounds.origin.y ?? -1)"
                    DispatchQueue.main.async { if let sv = sv, let h = FileHandle(forWritingAtPath: "/tmp/bridge-events.txt") { h.seekToEndOfFile(); h.write("   after: origin=\(sv.contentView.bounds.origin.y)\n".data(using: .utf8)!); try? h.close() } }
                }
                if let h = FileHandle(forWritingAtPath: "/tmp/bridge-events.txt") { h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close() }
                return e
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if let m = mon { NSEvent.removeMonitor(m) } }
            return
        }
        if name.hasPrefix("scroll:") {       // test hook: scroll:x,y,dy[,count] warps the pointer to x,y (points, top-left origin) and sends a trackpad-style gesture (began, changed x count, ended); negative dy = content up; needs Accessibility
            let p = name.dropFirst(7).split(separator: ",").compactMap { Double($0) }
            if p.count >= 3 {
                let pt = CGPoint(x: p[0], y: p[1])
                CGWarpMouseCursorPosition(pt); CGAssociateMouseAndMouseCursorPosition(1)
                let n = Int(p.count > 3 ? p[3] : 10)
                func post(_ phase: Int64, _ dy: Int32, _ after: Double) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
                        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                        e.location = pt
                        e.post(tap: .cghidEventTap)
                    }
                }
                post(1, 0, 0.2)
                for i in 0..<n { post(2, Int32(p[2]), 0.25 + 0.016 * Double(i)) }
                post(4, 0, 0.3 + 0.016 * Double(n))
            }
            return
        }
        if name.hasPrefix("peek:") {         // test hook: rest the pointer on x,y (points) for a moment, photograph the display to /tmp/bridge-screen.jpg, put the pointer back. Opens the Live Activity for a picture.
            // Optional third and fourth parts: seconds to wait (default 1.6) and "hold" to press and hold instead of hovering, e.g. peek:1016,26,2.5,hold
            let parts = name.dropFirst(5).split(separator: ",").map(String.init)
            let p = parts.prefix(2).compactMap { Double($0) }
            guard p.count == 2 else { return }
            let wait = parts.count > 2 ? (Double(parts[2]) ?? 1.6) : 1.6
            let hold = parts.count > 3 && parts[3] == "hold"
            let back = CGEvent(source: nil)?.location ?? .zero
            let at = CGPoint(x: p[0], y: p[1])
            func post(_ type: CGEventType, _ pt: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap) }
            post(.mouseMoved, at)
            if hold { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { post(.leftMouseDown, at) } }
            for i in 1...max(1, Int(wait / 0.3) - 1) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { post(hold ? .leftMouseDragged : .mouseMoved, CGPoint(x: at.x + CGFloat(i % 2), y: at.y)) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", "-t", "jpg", "/tmp/bridge-screen.jpg"]
                try? t.run(); t.waitUntilExit()
                if hold { post(.leftMouseUp, at) }
                post(.mouseMoved, back)
            }
            return
        }
        if name.hasPrefix("island-alert") {  // test hook: an alert update makes macOS open the Live Activity by itself (one chime, no pointer); photographs the display after N seconds (island-alert:2)
            if activity == nil { updateActivity(force: true) }
            guard let a = activity else { try? "no activity".write(toFile: "/tmp/bridge-island.err", atomically: true, encoding: .utf8); return }
            let wait = Double(name.split(separator: ":").dropFirst().first ?? "") ?? 1.6
            let st = a.content.state
            Task { await a.update(ActivityContent(state: st, staleDate: Date().addingTimeInterval(900), relevanceScore: 100), alertConfiguration: AlertConfiguration(title: "Bridge", body: "Live Activity check", sound: .default)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", "-t", "jpg", "/tmp/bridge-screen.jpg"]
                try? t.run()
            }
            return
        }
        if name.hasPrefix("notch") {         // test hook: notch:open[:seconds] opens the big island panel, holds it open and photographs the display after 1 s; notch:close folds it
            let parts = name.split(separator: ":").map(String.init)
            if parts.count > 1, parts[1] == "close" { NotchPanel.shared.close(); return }
            if NotchPanel.shared.model.state == nil { updateActivity(force: true) }
            NotchPanel.shared.open(pin: Double(parts.count > 2 ? parts[2] : "") ?? 4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", "-t", "jpg", "/tmp/bridge-screen.jpg"]
                try? t.run()
            }
            return
        }
        if name == "close-window" { NSApp.windows.first(where: { $0.title == "Bridge" && $0.canBecomeMain })?.close(); return }
        if name == "screen" {   // whole display, taken by Bridge itself (it holds Screen Recording); used to check the menu bar Live Activity
            let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", "-t", "jpg", "/tmp/bridge-screen.jpg"]
            try? t.run(); return
        }
        if name == "grant-all" { Task { await perms.requestAll(kit: kit, locator: locator) }; return }
        requestedPane = name
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let w = NSApp.windows.first(where: { $0.title == "Bridge" && $0.contentView != nil }), let v = w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
                try? "no window".write(toFile: "/tmp/bridge-ui-\(name).err", atomically: true, encoding: .utf8)
                return
            }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/bridge-ui-\(name).png"))
        }
    }

    /// Puts Bridge in the Accessibility list (macOS shows its own prompt) and opens that settings page. The switch itself is the owner's to flip.
    func askAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) { say("Bridge can already type into other apps."); return }
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    // MARK: commands
    func cli(_ args: [String], quiet: Bool = false, then: ((Bool, String) -> Void)? = nil) {
        Task {
            let r = await bg { runBridge(args) }
            let ok = r.0 == 0
            if !quiet || !ok { say(r.1.components(separatedBy: "\n").first ?? "") }
            then?(ok, r.1)
        }
    }

    func say(_ s: String) {
        toast = s
        let mine = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if self.toast == mine { self.toast = "" } }
    }

    func setting(_ k: String) -> Bool { ["1", "true", "on", "yes"].contains(snap?.settings[k] ?? "") }
    func set(_ k: String, _ on: Bool) { cli(["config", k, on ? "1" : "0"], quiet: true) }

    // MARK: feeds this app owns
    func pushKit() async {
        let cal = kit.calendarPayload()
        let rem = await kit.remindersPayload()
        _ = await bg { runBridge(["ingest", "calendar"], stdin: cal) }
        _ = await bg { runBridge(["ingest", "reminders"], stdin: rem) }
    }

    // MARK: actions the engine queues for this app
    func runActions() {
        guard let s = snap else { return }
        for a in s.actions where a.status == "queued" && !running.contains(a.id) {
            if a.exec == "app" {
                running.insert(a.id)
                Task { await execNative(a) }
            } else if a.exec == "app-py" {
                running.insert(a.id)
                let id = String(a.id)
                DispatchQueue.global().async { _ = runBridge(["action-run", id]) }
            }
        }
    }

    func execNative(_ a: BAction) async {
        let id = String(a.id)
        let started = await bg { runBridge(["action-start", id]) }
        guard started.1 == "OK" else { return }
        var res: (Bool, String) = (false, "no executor for \(a.kind)")
        switch a.kind {
        case "reminder.add", "reminder.complete", "reminder.archive", "event.add", "event.remove":
            res = await kit.perform(a)
        case "app.quit":
            let path = a.payload["path"] ?? ""
            if let app = ClaudeApps.running(path) {
                res = app.terminate() ? (true, "asked \(a.payload["name"] ?? "the app") to quit") : (false, "it refused to quit")
            } else { res = (true, "\(a.payload["name"] ?? "the app") was not running") }
        case "vault.fill":
            res = vault.fill(a.payload)
        case "vault.import":
            res = await importVaultCore(URL(fileURLWithPath: a.payload["path"] ?? ""))
        default: break
        }
        let out = res
        _ = await bg { runBridge(["action-finish", id, out.0 ? "ok" : "fail", out.1]) }
        if a.kind.hasPrefix("reminder") || a.kind.hasPrefix("event") { await pushKit() }
    }

    // MARK: tell the owner when something new needs him
    func notifyNew() {
        guard let s = snap else { return }
        var keys: [(String, String, String)] = s.attention.map { ("N\($0.id)", $0.kind == "signin" ? "Sign-in needed" : "Bridge needs you", $0.title) }
        keys += s.actions.filter { $0.status == "approval" }.map { ("A\($0.id)", "Approve?", $0.summary) }
        for k in keys where !notified.contains(k.0) {
            notified.insert(k.0)
            if primed { Notifier.post(k.1, k.2) }
        }
        primed = true
    }

    // MARK: Live Activity
    func state(of id: String) -> String { snap?.runners.first { $0.id == id }?.state ?? "unknown" }

    func updateActivity(force: Bool = false) {
        guard let s = snap else { if force { try? "\(Date())  no snapshot yet\n".write(toFile: "/tmp/bridge-activity.log", atomically: true, encoding: .utf8) }; return }
        if s.settings["live_activity"] == "0" {
            if let a = activity { Task { await a.end(nil, dismissalPolicy: .immediate) }; activity = nil; activityOn = false }
            NotchPanel.shared.feed(nil, enabled: false)
            return
        }
        let live = s.tasks.filter { $0.live }
        let open = s.tasks.filter { !$0.isDone && !$0.live && ["any", "ultra", "pro", "local"].contains($0.forWho) }
        let working = live.map { "\(($0.holder ?? "").capitalized) · T\($0.id) \($0.title)" }
        let waiting = open.prefix(4).map { "T\($0.id) \($0.title)" + ($0.due != nil ? " · \(dueText($0.due))" : "") }
        NotchPanel.shared.enabled = s.settings["big_island"] == "1"
        func on(_ id: String) -> String {
            if let p = s.runners.first(where: { $0.id == id })?.probe, let t = p.running?.first { return t }
            return live.first(where: { $0.holder == id }).map { "T\($0.id) \($0.title)" } ?? ""
        }
        var st = BridgeAttributes.ContentState(ultra: state(of: "ultra"), pro: state(of: "pro"), local: state(of: "local"), openCount: open.count,
                                               needs: s.counts.needs, working: working, waiting: Array(waiting), updated: Date())
        st.done = s.counts.doneToday
        st.mine = s.counts.needs + s.counts.naren
        st.ultraOn = on("ultra"); st.proOn = on("pro"); st.localOn = on("local")
        func since(_ id: String) -> Date? { s.runners.first(where: { $0.id == id })?.since.map { Date(timeIntervalSince1970: $0) } }
        st.ultraSince = since("ultra"); st.proSince = since("pro"); st.localSince = since("local")
        let f = trackFocus(s, live, st)
        st.focus = f.focus; st.focusPct = f.pct
        st.justDone = Date() < justDoneUntil ? justDone : ""
        let key = [state(of: "ultra"), state(of: "pro"), state(of: "local"), "\(open.count)", "\(s.counts.needs)", "\(s.counts.naren)", "\(s.counts.doneToday)",
                   st.focus, "\(Int((max(st.focusPct, -0.01)) * 100))", st.justDone].joined(separator: "|") + working.joined() + waiting.joined() + s.runners.compactMap { $0.probe?.running?.first }.joined()
        if key == lastKey && activity != nil && !force && pendingAlert == nil { return }
        NotchPanel.shared.feed(st, enabled: s.settings["big_island"] == "1")      // the big island panel draws the same state
        let content = ActivityContent(state: st, staleDate: Date().addingTimeInterval(900), relevanceScore: 100)   // Nov 21 04:28: the owner wants Bridge in the island; other Live Activities (Shortcuts etc.) drop to menu bar ovals
        // Nov 21: macOS can dismiss or end the activity behind our back (relaunch, reinstall, the agent indicator). A dead
        // reference meant Bridge kept "updating" an island nobody could see. Drop it and ask for a new one.
        if let a = activity, a.activityState != .active {
            Self.alog("activity was \(a.activityState); requesting a new one")
            activity = nil; activityOn = false; lastKey = ""
        }
        if let a = activity {
            lastKey = key
            if let alert = pendingAlert {
                pendingAlert = nil
                // The island expands with the alert and plays a sound: this is the "it's done" notification.
                let cfg = AlertConfiguration(title: LocalizedStringResource(stringLiteral: alert.title),
                                             body: LocalizedStringResource(stringLiteral: alert.body), sound: .default)
                Task { await a.update(content, alertConfiguration: cfg) }
            } else {
                Task { await a.update(content) }
            }
            return
        }
        // Nov 19, 2026: the Live Activity must come back by itself when Bridge starts in the background (relaunch, reinstall,
        // self-repair), not only when the owner brings the window forward. Retry at most every 20 s if macOS refuses.
        // Nov 20, 2026: never more than one Live Activity. Adopt an existing one and end extras instead of requesting another.
        let current = Activity<BridgeAttributes>.activities.filter { $0.activityState == .active }
        if let first = current.first {
            for extra in current.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
            activity = first; lastKey = key; activityOn = true
            Task { await first.update(content) }
            return
        }
        guard force || NSApp.isActive || Date().timeIntervalSince(lastRequest) > 20 else { return }
        lastRequest = Date()
        do {
            activity = try Activity.request(attributes: BridgeAttributes(), content: content, pushType: nil)
            lastKey = key
            activityOn = true
        } catch {
            activityOn = false
            if "\(error)".contains("visibility") { bounceForActivity() }
            let why = "\(Date())  Activity.request failed: \(error)  enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)\n"
            if let h = FileHandle(forWritingAtPath: "/tmp/bridge-activity.log") { h.seekToEndOfFile(); h.write(why.data(using: .utf8)!); h.closeFile() }
            else { try? why.write(toFile: "/tmp/bridge-activity.log", atomically: true, encoding: .utf8) }
        }
    }

    // MARK: Live Activity revival (Nov 21, 2026)
    // macOS only lets an app start a Live Activity while it is frontmost ("visibility"). After a relaunch in the background
    // (watchdog, rebuild, crash) the island stayed gone until the owner clicked Bridge. Now Bridge steps in front for a moment,
    // starts the activity, and hands focus straight back to the app he was in. At most once every 2 minutes.
    private var lastBounce = Date.distantPast
    static func alog(_ s: String) {
        let line = "\(Date())  \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/bridge-activity.log") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: "/tmp/bridge-activity.log", atomically: true, encoding: .utf8) }
    }
    private func bounceForActivity() {
        guard !NSApp.isActive, Date().timeIntervalSince(lastBounce) > 120 else { return }
        lastBounce = Date()
        let prev = NSWorkspace.shared.frontmostApplication
        Self.alog("visibility refused: stepping in front to start the island (back to \(prev?.localizedName ?? "?"))")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.lastRequest = .distantPast
            self.updateActivity(force: true)
            Self.alog("after bounce: activity=\(self.activity != nil)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { prev?.activate() }
        }
    }

    // MARK: Current-task progress + "done" alert (Nov 21, 2026)
    // The island's fill follows the task in front of you, not the day. A runner can report a real figure in its heartbeat
    // ("bridge hb T5 '60% tests pass'"); otherwise the fill runs on elapsed time against that runner's usual task length
    // (median of its last 20, learned here), eases toward 95% and never claims done. When the task finishes, the Live
    // Activity alerts (island expands, sound) and the slot flashes full with a tick for 12 s.
    private var liveSeen: [Int: (start: Date, holder: String, title: String)] = [:]
    private var chatSince: [String: Date] = [:]
    private var chatStop: [String: Date] = [:]
    private var chatTitle: [String: String] = [:]
    private var justDone = ""
    private var justDoneUntil = Date.distantPast
    private var pendingAlert: (title: String, body: String)?

    private func expected(_ key: String, _ fallback: Double) -> Double {
        let d = (UserDefaults.standard.array(forKey: "taskDur." + key) as? [Double]) ?? []
        guard d.count >= 3 else { return fallback }
        let s = d.sorted(); return max(45, s[s.count / 2])
    }
    private func record(_ key: String, _ secs: Double) {
        guard secs > 60, secs < 6 * 3600 else { return }   // under a minute: tests and instant answers, not a task length
        var d = (UserDefaults.standard.array(forKey: "taskDur." + key) as? [Double]) ?? []
        d.append(secs); if d.count > 20 { d.removeFirst(d.count - 20) }
        UserDefaults.standard.set(d, forKey: "taskDur." + key)
    }
    static func estimate(elapsed e: Double, expected x: Double) -> Double {
        let knee = 0.8 * x
        if e < knee { return max(0.03, e / x) }
        return 0.8 + 0.15 * (1 - exp(-(e - knee) / (0.5 * x)))
    }
    static func reported(_ text: String?) -> Double? {
        guard let t = text, let r = t.range(of: #"\b(\d{1,3})\s?%"#, options: .regularExpression) else { return nil }
        guard let n = Double(t[r].filter(\.isNumber)) else { return nil }
        return min(max(n / 100, 0), 0.99)
    }
    static func flog(_ s: String) {
        let line = "\(Date())  \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/bridge-focus.log") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: "/tmp/bridge-focus.log", atomically: true, encoding: .utf8) }
    }
    /// `label` is what the island shows for 12 s: "T115 Credit re-freeze" or "Pro · Account-free features".
    private func finished(_ title: String, _ body: String, label: String) {
        Self.flog("finished: \(title) — \(body) · activity=\(activity != nil)")
        justDone = label; justDoneUntil = Date().addingTimeInterval(12)
        pendingAlert = (title, body)
        if activity == nil { Notifier.post(title, body) }   // no Live Activity running: fall back to a banner
    }

    private func trackFocus(_ s: Snapshot, _ live: [BTask], _ st: BridgeAttributes.ContentState) -> (focus: String, pct: Double) {
        let now = Date()
        let byId = Dictionary(s.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func runnerSince(_ id: String) -> Date? { s.runners.first(where: { $0.id == id })?.since.map { Date(timeIntervalSince1970: $0) } }

        // Board tasks: first time seen live, and the moment they leave live as done.
        for t in live where liveSeen[t.id] == nil {
            let h = t.holder ?? "any"
            Self.flog("live: T\(t.id) \(h)")
            liveSeen[t.id] = (min(now, runnerSince(h) ?? now), h, t.title)
        }
        var doneBy = Set<String>()
        for (id, seen) in liveSeen where !live.contains(where: { $0.id == id }) {
            liveSeen[id] = nil
            guard let t = byId[id], t.isDone else { continue }       // released or reassigned: no alert
            record(seen.holder, now.timeIntervalSince(seen.start))
            doneBy.insert(seen.holder)
            let res = (t.result ?? "").split(separator: "\n").first.map(String.init) ?? ""
            finished("T\(id) done", "\(Glance.name(seen.holder)): \(t.title)" + (res.isEmpty ? "" : " — " + String(res.prefix(140))), label: "T\(id) \(t.title)")
        }

        // Chat work with no board task (Ultra / Pro in a conversation): done when the runner stops working for 20 s.
        for r in ["ultra", "pro"] {
            let state = r == "ultra" ? st.ultra : st.pro
            let holdsTask = live.contains { $0.holder == r }
            if state == "working" {
                chatStop[r] = nil
                if chatSince[r] == nil { chatSince[r] = runnerSince(r) ?? now }
                let on = r == "ultra" ? st.ultraOn : st.proOn
                if !on.isEmpty { chatTitle[r] = on }
            } else if let start = chatSince[r] {
                let stop = chatStop[r] ?? now
                chatStop[r] = stop
                if now.timeIntervalSince(stop) >= 20 {
                    chatSince[r] = nil; chatStop[r] = nil
                    let secs = stop.timeIntervalSince(start)
                    if !holdsTask && !doneBy.contains(r) && secs >= 90 && !Glance.off(state) {
                        record("chat." + r, secs)
                        let title = chatTitle[r].map { Glance.split($0).title.isEmpty ? $0 : Glance.split($0).title } ?? "its chat"
                        finished("\(Glance.name(r)) finished", title + (state == "waiting" ? " — waiting on you" : ""), label: "\(Glance.name(r)) · \(title)")
                    }
                    chatTitle[r] = nil
                }
            }
        }

        // What the fill shows: the runner the island leads with (Glance.current), its board task if it holds one.
        guard let r = Glance.current(st) else { return ("", -1) }
        if let t = live.first(where: { $0.holder == r.id }) {
            if let p = Self.reported(t.progress) { return ("T\(t.id)", p) }
            let start = liveSeen[t.id]?.start ?? now
            return ("T\(t.id)", Self.estimate(elapsed: now.timeIntervalSince(start), expected: expected(r.id, r.id == "local" ? 240 : 600)))
        }
        guard r.state == "working", let start = chatSince[r.id] ?? r.since else { return (r.code, -1) }
        return (r.code, Self.estimate(elapsed: now.timeIntervalSince(start), expected: expected("chat." + r.id, 300)))
    }

    // MARK: vault import
    @Published var vaultBusy: String? = nil
    @Published var vaultLast: String = ""

    // Runs off the main thread: a full Passwords export is ~1,500 Keychain writes and used to freeze the window.
    @discardableResult
    func importVaultCore(_ url: URL) async -> (Bool, String) {
        if vaultBusy != nil { return (false, "an import is already running") }
        vaultBusy = "Reading \(url.lastPathComponent)…"
        defer { vaultBusy = nil }
        let existing = snap?.vault?.items ?? []
        let v = vault
        let out: (Bool, String, [VaultItem]?) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let (rows, err) = Vault.importCSV(url)
                if rows.isEmpty { cont.resume(returning: (false, err, nil)); return }
                func key(_ i: VaultItem) -> String { i.title + "\u{1}" + (i.url ?? "") + "\u{1}" + (i.username ?? "") }
                var index = existing
                var pos: [String: Int] = [:]
                for (i, it) in index.enumerated() { pos[key(it)] = i }
                var added = 0, updated = 0, failed = 0
                for (n, r) in rows.enumerated() {
                    var item = r.item
                    let raw = item.url ?? ""
                    let host = URL(string: raw.contains("//") ? raw : "https://" + raw)?.host ?? ""
                    if let i = pos[key(item)] { item.id = index[i].id; index[i] = item; updated += 1 }
                    else { pos[key(item)] = index.count; index.append(item); added += 1 }
                    if !v.save(item.id, r.secret, label: "\(item.title) (\(host))") { failed += 1 }
                    if n % 25 == 0 { let msg = "Saving \(n + 1) of \(rows.count) to the Keychain…"; Task { @MainActor in if self.vaultBusy != nil { self.vaultBusy = msg } } }
                }
                let text = "\(added) added, \(updated) updated" + (failed > 0 ? ", \(failed) could not be saved to the Keychain" : "") + ". Secrets are in the Keychain."
                cont.resume(returning: (failed == 0, text, index))
            }
        }
        if let idx = out.2 { pushVaultIndex(idx) }
        vaultLast = out.1
        return (out.0, out.1)
    }

    func importVault(_ url: URL) {
        Task {
            let res = await importVaultCore(url)
            say("Vault: " + res.1)
            guard res.0 else { return }
            let alert = NSAlert()
            alert.messageText = "Delete the CSV now?"
            alert.informativeText = "\(url.lastPathComponent) holds every password in plain text. They are now in your Keychain, so the file is only a risk. Deleting it removes it for good."
            alert.addButton(withTitle: "Delete the file")
            alert.addButton(withTitle: "Keep it")
            if alert.runModal() == .alertFirstButtonReturn {
                do { try FileManager.default.removeItem(at: url); say("Deleted \(url.lastPathComponent).") } catch { say("Could not delete the file: \(error.localizedDescription)") }
            }
        }
    }

    func pushVaultIndex(_ items: [VaultItem]) {
        let rows: [[String: Any]] = items.map { ["id": $0.id, "title": $0.title, "url": $0.url ?? "", "username": $0.username ?? "", "has_otp": ($0.hasOtp ?? 0) == 1, "has_notes": ($0.hasNotes ?? 0) == 1] }
        let json = jsonString(rows)
        DispatchQueue.global().async { _ = runBridge(["vault-index"], stdin: json) }
    }

    func deleteVault(_ item: VaultItem) {
        vault.remove(item.id)
        pushVaultIndex((snap?.vault?.items ?? []).filter { $0.id != item.id })
    }

    func copySecret(_ item: VaultItem, _ what: String) {
        Task {
            guard await vault.unlock("copy the \(what) for \(item.title)") else { say("Not unlocked."); return }
            guard let sec = vault.load(item.id) else { say("That login is missing from the Keychain."); return }
            if what == "code" {
                guard let o = sec["o"], let c = Vault.totp(o) else { say("No one-time code stored."); return }
                vault.copy(c)
            } else {
                vault.copy(sec["p"] ?? "")
            }
            say("Copied the \(what) for \(item.title). Clipboard clears in 60 s.")
        }
    }
}
