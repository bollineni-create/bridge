#if os(iOS)
import Foundation
import UIKit

/// On the iPhone Duo. The phone can't run anything on the Mac, so it works through the iCloud bridge folder:
///   live/companion.json        the board, written by the Mac relay every few seconds
///   live/requests/<id>.json     what the phone wants done ({"id", "args"}), picked up by the relay
///   live/results/<id>.json      what came back ({"ok", "out"})
/// the owner picks the claude-bridge folder once; a security-scoped bookmark keeps access.
@MainActor
final class PhoneBackend: Backend {
    let name = "iCloud"
    let livePreview = false
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
        guard let url = live("companion.json") else { return }
        Self.readCoordinated(url) { data in
            guard let data, let s = try? JSONDecoder().decode(Snap.self, from: data) else { return }
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
}
#endif
