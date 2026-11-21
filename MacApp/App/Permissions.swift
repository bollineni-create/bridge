import SwiftUI
import AppKit
import AVFoundation
import Contacts
import Photos
import Speech
import CoreBluetooth
import CoreMotion
import MusicKit
import Intents
import Network
import IOKit.hid
import EventKit
import CoreLocation
import UserNotifications
import SQLite3

/// Results from the local-network probe, written by NWBrowser's handler on the main queue.
private final class NetFlag: @unchecked Sendable { var denied = false; var ready = false }

/// Automation answers collected from several threads.
private final class AutoCodes: @unchecked Sendable {
    private let lock = NSLock(); private var codes: [OSStatus] = []
    func add(_ c: OSStatus) { lock.lock(); codes.append(c); lock.unlock() }
    var all: [OSStatus] { lock.lock(); defer { lock.unlock() }; return codes }
}

/// Every row of System Settings > Privacy & Security, with what Bridge holds today.
/// "ask" rows show a macOS prompt; "manual" rows have no prompt on macOS, so Bridge opens the page and the owner flips the switch;
/// "none" rows are ones macOS does not offer to an app like this at all.
struct PermRow: Identifiable {
    enum How { case ask, manual, none }
    let id: String
    let name: String
    let how: How
    let pane: String
    let note: String
    var state: String = "unknown"     // granted | not granted | asked | unknown | not available
}

@MainActor
final class Permissions: ObservableObject {
    @Published var rows: [PermRow] = [
        PermRow(id: "calendar", name: "Calendars", how: .ask, pane: "Privacy_Calendars", note: ""),
        PermRow(id: "reminders", name: "Reminders", how: .ask, pane: "Privacy_Reminders", note: ""),
        PermRow(id: "location", name: "Location Services", how: .ask, pane: "Privacy_LocationServices", note: ""),
        PermRow(id: "notifications", name: "Notifications", how: .ask, pane: "", note: ""),
        PermRow(id: "contacts", name: "Contacts", how: .ask, pane: "Privacy_Contacts", note: ""),
        PermRow(id: "photos", name: "Photos", how: .ask, pane: "Privacy_Photos", note: ""),
        PermRow(id: "music", name: "Media & Apple Music", how: .ask, pane: "Privacy_Media", note: ""),
        PermRow(id: "camera", name: "Camera", how: .ask, pane: "Privacy_Camera", note: ""),
        PermRow(id: "microphone", name: "Microphone", how: .ask, pane: "Privacy_Microphone", note: ""),
        PermRow(id: "speech", name: "Speech Recognition", how: .ask, pane: "Privacy_SpeechRecognition", note: ""),
        PermRow(id: "bluetooth", name: "Bluetooth", how: .ask, pane: "Privacy_Bluetooth", note: ""),
        PermRow(id: "focus", name: "Focus", how: .ask, pane: "Privacy_Focus", note: ""),
        PermRow(id: "motion", name: "Motion & Fitness", how: .ask, pane: "Privacy_Motion", note: "macOS asks only while AirPods with motion sensors are connected"),
        PermRow(id: "localnet", name: "Local Network", how: .ask, pane: "Privacy_LocalNetwork", note: "read from a test Bonjour browse"),
        PermRow(id: "files", name: "Files & Folders (Desktop, Documents, Downloads)", how: .ask, pane: "Privacy_FilesAndFolders", note: ""),
        PermRow(id: "accessibility", name: "Accessibility", how: .ask, pane: "Privacy_Accessibility", note: "typing into other apps: vault fill, Pro hand-off"),
        PermRow(id: "input", name: "Input Monitoring", how: .ask, pane: "Privacy_ListenEvent", note: ""),
        PermRow(id: "screen", name: "Screen & System Audio Recording", how: .ask, pane: "Privacy_ScreenCapture", note: ""),
        PermRow(id: "automation", name: "Automation", how: .ask, pane: "Privacy_Automation", note: "one prompt per app Bridge controls; apps that are closed are asked on first use"),
        PermRow(id: "fda", name: "Full Disk Access", how: .manual, pane: "Privacy_AllFiles", note: "no prompt exists; turn on Bridge in the list"),
        PermRow(id: "appmgmt", name: "App Management", how: .manual, pane: "Privacy_AppBundles", note: "no prompt exists; add Bridge with + in the list"),
        PermRow(id: "devtools", name: "Developer Tools", how: .manual, pane: "Privacy_DevTools", note: "no prompt exists; add Bridge with + in the list"),
        PermRow(id: "home", name: "Home", how: .none, pane: "", note: "Apple offers HomeKit only to iPad-style apps; Bridge runs your scenes through Shortcuts"),
        PermRow(id: "passkeys", name: "Passkeys Access for Web Browsers", how: .none, pane: "", note: "only web browsers can hold this"),
        PermRow(id: "remote", name: "Remote Desktop", how: .none, pane: "", note: "only remote-control services can hold this"),
        PermRow(id: "override", name: "System & App Protection Override", how: .none, pane: "", note: "no public way for an app to ask"),
    ]
    @Published var busy = false
    private var bt: CBCentralManager?
    private var browser: NWBrowser?
    private let motion = CMHeadphoneMotionManager()
    private let clm = CLLocationManager()
    private var asked = Set<String>()
    private var lnBrowser: NWBrowser?
    // App Management is probed once per launch: a refused write makes macOS post a "prevented from modifying apps" notice.
    private var appMgmtDone = false
    private var appMgmtResult: Bool?
    nonisolated static let automationTargets = ["com.apple.systemevents", "com.apple.finder", "com.apple.Music", "com.apple.MobileSMS", "com.apple.Terminal", "com.apple.Safari",
                                    "com.google.Chrome", "com.apple.mail", "com.apple.Notes", "com.apple.reminders", "com.apple.iCal", "com.apple.Passwords"]

    var missing: Int { rows.filter { $0.how != .none && $0.state == "not granted" }.count }

    /// Leaves the list where runners can read it: bridge permissions
    func dump() {
        let lines = rows.map { "\($0.state)\t\($0.name)\t\($0.note)" }.joined(separator: "\n")
        let dir = NSHomeDirectory() + "/Library/Application Support/Bridge"
        try? lines.write(toFile: dir + "/permissions.tsv", atomically: true, encoding: .utf8)
    }

    private func set(_ id: String, _ ok: Bool?) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].state = ok == nil ? (asked.contains(id) ? "asked" : "unknown") : (ok! ? "granted" : "not granted")
    }

    func refresh() {
        set("calendar", EKEventStore.authorizationStatus(for: .event) == .fullAccess)
        set("reminders", EKEventStore.authorizationStatus(for: .reminder) == .fullAccess)
        let loc = CLLocationManager().authorizationStatus
        set("location", loc == .authorizedAlways || loc == .authorized)
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in self.set("notifications", ok) }
        }
        set("contacts", CNContactStore.authorizationStatus(for: .contacts) == .authorized)
        set("photos", PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized)
        set("music", MusicAuthorization.currentStatus == .authorized)
        set("camera", AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
        set("microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        set("speech", SFSpeechRecognizer.authorizationStatus() == .authorized)
        set("bluetooth", CBCentralManager.authorization == .allowedAlways)
        set("focus", INFocusStatusCenter.default.authorizationStatus == .authorized)
        set("motion", CMHeadphoneMotionManager.authorizationStatus() == .authorized)
        probeLocalNetwork()
        set("accessibility", AXIsProcessTrusted())
        set("input", IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
        set("screen", CGPreflightScreenCaptureAccess())
        let home = NSHomeDirectory()
        // Open files only Full Disk Access unlocks. (The user TCC.db stays locked even with the grant on newer macOS, so it can't be the test.)
        let fdaProbe = ["/Library/Messages/chat.db", "/Library/Safari/History.db", "/Library/Safari/Bookmarks.plist", "/Library/Mail"]
            .map { home + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        let fdaOpen = fdaProbe.contains { p in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            if isDir.boolValue { return (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil }
            guard let h = FileHandle(forReadingAtPath: p) else { return false }
            defer { try? h.close() }
            return (try? h.read(upToCount: 16)) != nil
        }
        set("fda", fdaProbe.isEmpty ? nil : fdaOpen)
        // Full Disk Access covers Desktop, Documents and Downloads. Without it, reading them would pop a prompt, so leave it unknown.
        set("files", fdaOpen ? true : nil)
        // Read the running-app list here on the main thread: off it, NSWorkspace can hand back an empty list,
        // which is why Automation sat at "unknown" even with Finder open.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let live = Permissions.automationTargets.filter { running.contains($0) }
        let needAppMgmt = !appMgmtDone
        // Automation: one thread per app, because AEDeterminePermissionToAutomateTarget can block on an app that isn't answering.
        // Whatever has answered after 2.5 s decides. noErr = allowed; -1743 = switched off; -1744 = never asked (not a denial).
        let codes = AutoCodes()
        for b in live { DispatchQueue.global().async { codes.add(Permissions.automation(b, ask: false)) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            let c = codes.all
            self?.set("automation", c.contains(-1743) ? false : (c.contains(noErr) ? true : nil))
            self?.dump()
        }
        Task.detached {
            let tcc = Permissions.systemTCC()
            let dev = tcc["kTCCServiceDeveloperTool"].map { $0 == 2 }
            let tccAppMgmt = tcc["kTCCServiceSystemPolicyAppBundles"].map { $0 == 2 }
            let probed: Bool? = (tccAppMgmt == nil && needAppMgmt) ? Permissions.appManagementProbe() : nil
            await MainActor.run {
                self.set("devtools", dev)
                if let t = tccAppMgmt { self.set("appmgmt", t) }
                else {
                    if needAppMgmt { self.appMgmtDone = true; self.appMgmtResult = probed }
                    self.set("appmgmt", self.appMgmtResult)
                }
                if self.rows.first(where: { $0.id == "fda" })?.state == "unknown", let f = tcc["kTCCServiceSystemPolicyAllFiles"] { self.set("fda", f == 2) }
                self.dump()
            }
        }
        for i in rows.indices where rows[i].how == .none { rows[i].state = "not available" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.dump() }
    }

    nonisolated static func automation(_ bundle: String, ask: Bool) -> OSStatus {
        let d = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let p = d.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(p, typeWildCard, typeWildCard, ask)
    }

    /// The system TCC database records grants that have no read-back API (Developer Tools, App Management, Full Disk Access).
    /// Bridge can open it because it holds Full Disk Access. Returns service -> auth_value (2 allowed, 0 denied).
    nonisolated static func systemTCC() -> [String: Int] {
        guard let bid = Bundle.main.bundleIdentifier else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2("/Library/Application Support/com.apple.TCC/TCC.db", &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [:] }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select service, auth_value from access where client = ?", -1, &st, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(st, 1, bid, -1, transient)
        var out: [String: Int] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            if let c = sqlite3_column_text(st, 0) { out[String(cString: c)] = Int(sqlite3_column_int(st, 1)) }
        }
        return out
    }

    /// App Management has no read-back API. Test it the way macOS enforces it: create a file inside another app's bundle, then remove it at once.
    /// Picks a user-owned, non-Apple app that isn't running, so file permissions allow the write and only App Management can refuse it.
    nonisolated static func appManagementProbe() -> Bool? {
        let fm = FileManager.default
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        let me = Bundle.main.bundleURL.standardizedFileURL.path
        guard let apps = try? fm.contentsOfDirectory(atPath: "/Applications") else { return nil }
        for name in apps.sorted() where name.hasSuffix(".app") {
            let app = "/Applications/" + name, contents = app + "/Contents"
            guard app != me, !running.contains(app),
                  let b = Bundle(path: app)?.bundleIdentifier, !b.hasPrefix("com.apple."),
                  let owner = (try? fm.attributesOfItem(atPath: contents))?[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid(),
                  access(contents, W_OK) == 0 else { continue }
            let probe = contents + "/.bridge-appmgmt-probe"
            let fd = Darwin.open(probe, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if fd >= 0 { close(fd); unlink(probe); return true }
            let e = errno
            if e == EEXIST { unlink(probe); continue }
            return (e == EPERM || e == EACCES) ? false : nil
        }
        return nil
    }

    /// Local Network has no status API, but a Bonjour browse fails with PolicyDenied (-65570) when it is switched off.
    private func probeLocalNetwork() {
        lnBrowser?.cancel()
        let b = NWBrowser(for: .bonjour(type: "_bridge._tcp", domain: nil), using: .tcp)
        lnBrowser = b
        let flag = NetFlag()
        b.stateUpdateHandler = { st in
            switch st {
            case .ready: flag.ready = true
            case .waiting(let e), .failed(let e):
                if case .dns(let c) = e, c == -65570 { flag.denied = true }
            default: break
            }
        }
        b.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            b.cancel()
            guard let self else { return }
            self.set("localnet", flag.denied ? false : (flag.ready ? true : nil))
            self.dump()
        }
    }

    func open(_ row: PermRow) {
        guard !row.pane.isEmpty, let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + row.pane) else { return }
        NSWorkspace.shared.open(u)
    }

    /// Ask for one thing. Each await returns when the owner has answered that prompt, so prompts never stack.
    func request(_ id: String, kit: Kit, locator: Locator) async {
        asked.insert(id)
        switch id {
        case "calendar", "reminders": await kit.request()
        case "location": clm.requestWhenInUseAuthorization(); try? await Task.sleep(nanoseconds: 1_000_000_000)
        case "notifications": _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        case "contacts": _ = try? await CNContactStore().requestAccess(for: .contacts)
        case "photos": _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case "music": _ = await MusicAuthorization.request()
        case "camera": _ = await AVCaptureDevice.requestAccess(for: .video)
        case "microphone": _ = await AVCaptureDevice.requestAccess(for: .audio)
        case "speech": await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } }
        case "bluetooth":
            bt = CBCentralManager(delegate: nil, queue: nil)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        case "focus": await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in INFocusStatusCenter.default.requestAuthorization { _ in c.resume() } }
        case "motion":
            if motion.isDeviceMotionAvailable { motion.startDeviceMotionUpdates(); try? await Task.sleep(nanoseconds: 1_500_000_000); motion.stopDeviceMotionUpdates() }
        case "localnet":
            let b = NWBrowser(for: .bonjour(type: "_bridge._tcp", domain: nil), using: .tcp)
            browser = b
            b.start(queue: .main)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        case "files":
            let home = NSHomeDirectory()
            for d in ["Desktop", "Documents", "Downloads"] { _ = try? FileManager.default.contentsOfDirectory(atPath: home + "/" + d) }
        case "accessibility":
            if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        case "input": _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case "screen": _ = CGRequestScreenCaptureAccess()
        case "automation":
            await Task.detached {
                let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
                for b in Permissions.automationTargets where running.contains(b) { _ = Permissions.automation(b, ask: true) }
            }.value
        case "fda":
            _ = try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Safari/History.db"), options: .mappedIfSafe)
            if let r = rows.first(where: { $0.id == "fda" }), r.state != "granted" { open(r) }
        case "appmgmt", "devtools":
            if let r = rows.first(where: { $0.id == id }) { open(r) }
        default: break
        }
        refresh()
    }

    /// "Request permission to all of these": every prompt macOS has, one after another, skipping what is already granted.
    func requestAll(kit: Kit, locator: Locator) async {
        guard !busy else { return }
        busy = true
        refresh()
        try? await Task.sleep(nanoseconds: 600_000_000)
        for r in rows where r.how == .ask && r.state != "granted" { await request(r.id, kit: kit, locator: locator) }
        for r in rows where r.how == .manual && r.state != "granted" && r.id == "fda" { await request(r.id, kit: kit, locator: locator) }
        busy = false
        refresh()
    }
}

struct PermissionsCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject var perms: Permissions
    // Orange only for a real "not granted". Unknown/asked are states macOS won't report, not problems.
    func color(_ s: String) -> Color { s == "granted" ? Ink.good : (s == "not granted" ? Ink.warn : Ink.faint) }
    func icon(_ r: PermRow) -> String {
        if r.state == "granted" { return "checkmark.circle.fill" }
        if r.how == .none { return "minus.circle" }
        return r.state == "not granted" ? "exclamationmark.triangle.fill" : "questionmark.circle"
    }
    var body: some View {
        Card(pad: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(perms.missing == 0 ? "Nothing is switched off. Rows marked unknown cannot be read back by any app." : "\(perms.missing) not granted yet")
                        .font(SW.a(14, 600))
                    Spacer()
                    Button(perms.busy ? "Asking…" : "Request everything") { Task { await perms.requestAll(kit: store.kit, locator: store.locator) } }
                        .buttonStyle(QuietButton(color: Ink.good)).disabled(perms.busy)
                }
                ForEach(perms.rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: icon(r))
                            .foregroundStyle(color(r.state)).font(SW.a(13.5, 400))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(SW.a(13.5, 500))
                            Text(r.note.isEmpty ? r.state : r.state + " · " + r.note).font(SW.a(13, 400)).foregroundStyle(Ink.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if r.how != .none && r.state != "granted" {
                            Button(r.how == .ask ? "Ask" : "Open") { Task { await perms.request(r.id, kit: store.kit, locator: store.locator) } }
                                .buttonStyle(QuietButton(color: r.state == "not granted" ? Ink.warn : Ink.faint))
                            if r.how == .ask && !r.pane.isEmpty { Button("Settings") { perms.open(r) }.buttonStyle(QuietButton()) }
                        }
                    }
                }
            }
        }
        .onAppear { perms.refresh() }
    }
}
