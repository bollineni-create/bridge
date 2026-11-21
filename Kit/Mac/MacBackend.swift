#if os(macOS)
import Foundation
import AppKit

/// On the Mac: read the snapshot Bridge's engine writes every second, act through the `bridge` CLI as the owner.
@MainActor
final class MacBackend: Backend {
    let name = "engine"
    let livePreview = true
    private let path = NSHomeDirectory() + "/Library/Application Support/Bridge/snapshot.json"
    private let aiRoot = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/AI/"
    private var lastMod: Date?
    private var timer: Timer?
    private var onSnap: ((Snap) -> Void)?
    static let bin = ["/opt/homebrew/bin/bridge", "/usr/local/bin/bridge"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/bridge"

    private var watcher: DispatchSourceFileSystemObject?
    func start(_ onSnap: @escaping (Snap) -> Void) {
        self.onSnap = onSnap
        poll()
        // Redraw the moment the engine writes: watch the folder (snapshot.json is replaced atomically, so its own fd goes stale).
        let fd = Darwin.open((path as NSString).deletingLastPathComponent, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.poll() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watcher = src
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }   // safety net
    }
    private func modDate() -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
    func age() -> TimeInterval? { modDate().map { Date().timeIntervalSince($0) } }
    private func poll(force: Bool = false) {
        guard let mod = modDate(), force || mod != lastMod else { return }
        lastMod = mod
        let p = path
        DispatchQueue.global(qos: .userInitiated).async {
            guard let d = FileManager.default.contents(atPath: p), let s = try? JSONDecoder().decode(Snap.self, from: d) else { return }
            DispatchQueue.main.async { self.onSnap?(s) }
        }
    }

    func run(_ args: [String], done: @escaping (Bool, String) -> Void) {
        let bin = Self.bin
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env.removeValue(forKey: "BRIDGE_AS")            // acts as the owner, the CLI's default
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            var out = "", ok = false
            do {
                try p.run()
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                out = String(decoding: d, as: UTF8.self); ok = p.terminationStatus == 0
            } catch { out = "ERROR: the bridge command isn't installed" }
            // Every button press that reaches the CLI is logged, so a silent failure can't hide.
            let logDir = NSHomeDirectory() + "/Library/Logs/Bridge"
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            let line = "\(Date()) ok=\(ok) bridge \(args.joined(separator: " ")) -> \(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))\n"
            if let h = FileHandle(forWritingAtPath: logDir + "/cli.log") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(toFile: logDir + "/cli.log", atomically: true, encoding: .utf8) }
            let o = out, k = ok
            DispatchQueue.main.async { done(k, o); self.poll(force: true) }
        }
    }

    func readOutput(_ path: String) -> String? {
        let full = path.hasPrefix("/") ? path : aiRoot + path
        guard let s = try? String(contentsOfFile: full, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 3000 ? String(t.prefix(3000)) + "…" : t
    }

    func openRunner(_ id: String) {
        let app = id == "ultra" ? "/Applications/Claude.app" : (id == "pro" ? "/Applications/Claude 2.app" : "")
        if !app.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
        else if let u = URL(string: "bridge://open/local") { NSWorkspace.shared.open(u) }
    }
    func open(url: URL) { NSWorkspace.shared.open(url) }
}

extension Store {
    /// The Mac companion: Bridge's live snapshot + the bridge CLI.
    public static func mac() -> Store { Store(backend: MacBackend()) }
    /// One store for every Bridge window on the Mac (compact window and the main window's panes).
    public static let sharedMac = Store.mac()
}
#endif
