#if os(iOS)
import Foundation
import UIKit

/// On the iPhone Duo. Two paths to the Mac, tried in this order:
///   Direct (Tailscale): the Mac relay's private server, found through live/phone-link.json (address + pairing key).
///     About a second, from anywhere the phone has Tailscale on. GET /companion is the board, POST /run runs a command.
///   iCloud (fallback, can take minutes), through the bridge folder:
///   live/companion.json        the board, written by the Mac relay every few seconds
///   live/requests/<id>.json     what the phone wants done ({"id", "args"}), picked up by the relay
///   live/results/<id>.json      what came back ({"ok", "out"})
/// the owner picks the claude-bridge folder once; a security-scoped bookmark keeps access.
@MainActor
final class PhoneBackend: Backend {
    /// Which path the last successful read or command used: shown with the update time.
    var name: String { direct ? "Tailscale" : "iCloud" }
    let livePreview = false
    private var direct = false
    private struct Link: Codable { var url: String?; var ip_url: String?; var token: String }
    private var link: Link? = {
        guard let d = UserDefaults.standard.data(forKey: "bridgeDirectLink") else { return nil }
        return try? JSONDecoder().decode(Link.self, from: d)
    }()
    private var linkCheckedAt = Date.distantPast
    private var directDownUntil = Date.distantPast       // after a failure, use iCloud for a little while before trying again
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    /// Commands can take a while on the Mac (Qwen or a sync holding the database), so they get their own, patient session.
    private let runSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 100
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    /// Only these mean the request never reached the Mac, so it is safe to send it again through iCloud.
    private static func neverArrived(_ e: Error?) -> Bool {
        guard let u = e as? URLError else { return false }
        return [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                .callIsActive, .dataNotAllowed, .secureConnectionFailed].contains(u.code)
    }
    private(set) var folder: URL?
    private var onSnap: ((Snap) -> Void)?
    private var timer: Timer?
    private var generated: Double?
    private static let key = "bridgeFolderBookmark"

    init() {
        folder = Self.restore()
        #if targetEnvironment(simulator)
        // Testing in the simulator, which can't sign into iCloud: read the Mac's bridge folder directly.
        if folder == nil, let p = ProcessInfo.processInfo.environment["BRIDGE_FOLDER"] { folder = URL(fileURLWithPath: p, isDirectory: true) }
        #endif
    }

    var hasFolder: Bool { folder != nil }

    func setFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        folder = url
        poll()
    }
    private static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: key) }
        return url
    }

    private func live(_ name: String) -> URL? { folder?.appendingPathComponent("live", isDirectory: true).appendingPathComponent(name) }

    func start(_ onSnap: @escaping (Snap) -> Void) {
        self.onSnap = onSnap
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }
    func age() -> TimeInterval? { generated.map { Date().timeIntervalSince1970 - $0 } }

    func poll() {
        refreshLink()
        directGet { ok in if !ok { self.pollICloud() } }
    }

    // MARK: direct path
    private var directBases: [URL] {
        guard let l = link, Date() >= directDownUntil else { return [] }
        return [l.url, l.ip_url].compactMap { $0.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    }
    /// Re-reads phone-link.json from iCloud now and then (the Mac rewrites it if its address or key changes).
    private func refreshLink() {
        guard Date().timeIntervalSince(linkCheckedAt) > 30 else { return }
        linkCheckedAt = Date()
        // 1. A copy in the app's own Documents (pushed over USB when pairing; readable even while the phone is locked).
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? Data(contentsOf: docs.appendingPathComponent("phone-link.json")) { applyLink(data) }
        // 2. The one the Mac keeps in the iCloud bridge folder (follows address or key changes).
        guard let url = live("phone-link.json") else { return }
        Self.readCoordinated(url) { data in if let data { self.applyLink(data) } }
    }
    private func applyLink(_ data: Data) {
        guard let l = try? JSONDecoder().decode(Link.self, from: data), !l.token.isEmpty else { return }
        if let enc = try? JSONEncoder().encode(l) { UserDefaults.standard.set(enc, forKey: "bridgeDirectLink") }
        let changed = link?.token != l.token || link?.url != l.url
        link = l
        if changed { directDownUntil = .distantPast; direct = false }
    }
    private func request(_ base: URL, _ path: String, body: Data? = nil, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        r.setValue("Bearer " + (link?.token ?? ""), forHTTPHeaderField: "Authorization")
        if let body { r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }
    private func directGet(_ done: @escaping (Bool) -> Void) {
        let bases = directBases
        guard !bases.isEmpty else { done(false); return }
        func attempt(_ i: Int) {
            guard i < bases.count else {
                self.direct = false
                self.directDownUntil = Date().addingTimeInterval(20)
                done(false); return
            }
            session.dataTask(with: request(bases[i], "companion", timeout: 4)) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                let snap = ok ? data.flatMap { try? JSONDecoder().decode(Snap.self, from: $0) } : nil
                DispatchQueue.main.async {
                    guard let s = snap else { attempt(i + 1); return }
                    self.direct = true
                    self.generated = s.generated
                    self.onSnap?(s)
                    done(true)
                }
            }.resume()
        }
        attempt(0)
    }
    private func directRun(_ args: [String], _ done: @escaping (Bool, String) -> Void, fallback: @escaping () -> Void) {
        let bases = directBases
        guard !bases.isEmpty, let body = try? JSONSerialization.data(withJSONObject: ["args": args]) else { fallback(); return }
        func attempt(_ i: Int) {
            guard i < bases.count else {
                self.direct = false
                self.directDownUntil = Date().addingTimeInterval(20)
                fallback(); return
            }
            runSession.dataTask(with: request(bases[i], "run", body: body, timeout: 100)) { data, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async {
                    guard code == 200, let j else {
                        if code == 401 { self.linkCheckedAt = .distantPast; attempt(i + 1); return }   // key changed on the Mac
                        if code == 0 && !Self.neverArrived(err) {
                            // It may already be running on the Mac: never send it twice. The board will show the result.
                            self.direct = true
                            done(true, "Sent to your Mac; it's still working on it.")
                            return
                        }
                        attempt(i + 1); return
                    }
                    self.direct = true
                    done((j["ok"] as? Bool) ?? false, (j["out"] as? String) ?? "")
                    self.poll()
                }
            }.resume()
        }
        attempt(0)
    }

    // MARK: iCloud path
    private func pollICloud() {
        guard let url = live("companion.json") else { return }
        Self.readCoordinated(url) { data in
            guard let data, let s = try? JSONDecoder().decode(Snap.self, from: data) else { return }
            self.direct = false
            self.generated = s.generated
            self.onSnap?(s)
        }
    }

    /// Reads through NSFileCoordinator and asks iCloud to fetch the newest copy.
    nonisolated static func readCoordinated(_ url: URL, _ done: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var data: Data?
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &err) { u in data = try? Data(contentsOf: u) }
            DispatchQueue.main.async { done(data) }
        }
    }

    func run(_ args: [String], done: @escaping (Bool, String) -> Void) {
        directRun(args, done) { self.runICloud(args, done: done) }
    }

    private func runICloud(_ args: [String], done: @escaping (Bool, String) -> Void) {
        guard let reqDir = live("requests"), let resDir = live("results") else { done(false, "ERROR: pick your claude-bridge folder first"); return }
        let id = UUID().uuidString
        let body: [String: Any] = ["id": id, "args": args, "from": "iphone", "ts": Date().timeIntervalSince1970]
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: reqDir, withIntermediateDirectories: true)
            var err: NSError?
            var wrote = false
            NSFileCoordinator().coordinate(writingItemAt: reqDir.appendingPathComponent(id + ".json"), options: [], error: &err) { u in
                wrote = (try? JSONSerialization.data(withJSONObject: body).write(to: u, options: .atomic)) != nil
            }
            DispatchQueue.main.async {
                guard wrote else { done(false, "ERROR: couldn't write to iCloud"); return }
                self.waitResult(resDir.appendingPathComponent(id + ".json"), tries: 0, done: done)
            }
        }
    }

    /// The relay answers within a few seconds while the Mac is awake; iCloud adds its own delay.
    private func waitResult(_ url: URL, tries: Int, done: @escaping (Bool, String) -> Void) {
        Self.readCoordinated(url) { data in
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                done((j["ok"] as? Bool) ?? false, (j["out"] as? String) ?? "")
                self.poll()
                return
            }
            if tries >= 45 { done(true, "Sent. Your Mac will run it when it next syncs."); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.waitResult(url, tries: tries + 1, done: done) }
        }
    }

    func readOutput(_ path: String) -> String? {
        guard let folder else { return nil }
        let rel = path.hasPrefix("claude-bridge/") ? String(path.dropFirst("claude-bridge/".count)) : path
        let url = folder.appendingPathComponent(rel)
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 3000 ? String(t.prefix(3000)) + "…" : t
    }

    func openRunner(_ id: String) {
        // Ultra and Pro are both in the Claude app on the phone; Qwen lives on the Mac.
        if id != "local", let u = URL(string: "claude://") { UIApplication.shared.open(u) }
    }
    func open(url: URL) { UIApplication.shared.open(url) }
}

extension Store {
    /// The iPhone companion, reading and writing through the iCloud bridge folder.
    public static func phone() -> (Store, PhoneLink) {
        let b = PhoneBackend()
        return (Store(backend: b), PhoneLink(b))
    }
}

/// What the iPhone app shell needs from the backend: whether a folder is picked, and a way to pick it.
@MainActor
public final class PhoneLink: ObservableObject {
    private let b: PhoneBackend
    @Published public var hasFolder: Bool
    init(_ b: PhoneBackend) { self.b = b; hasFolder = b.hasFolder }
    public func setFolder(_ url: URL) { b.setFolder(url); hasFolder = b.hasFolder }
    public func refresh() { b.poll() }
    public func pull() async { b.poll(); try? await Task.sleep(for: .milliseconds(700)) }
}
#endif
