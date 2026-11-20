// Renders Bridge's real SwiftUI screens with demo data to PNG, for the README and bollineni.co.
// No personal data: everything below is invented. Build: see Tools/shots.sh
import SwiftUI
import AppKit
import CoreText

@MainActor
final class DemoBackend: Backend {
    let name = "demo"
    let livePreview = false
    let snap: Snap
    init(_ s: Snap) { snap = s }
    func start(_ onSnap: @escaping (Snap) -> Void) { onSnap(snap) }
    func age() -> TimeInterval? { 1 }
    func run(_ args: [String], done: @escaping (Bool, String) -> Void) { done(true, "") }
    func readOutput(_ path: String) -> String? { nil }
    func openRunner(_ id: String) {}
    func open(url: URL) {}
}

let now = Date().timeIntervalSince1970
let cal = Calendar.current
func day(_ d: Int) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: cal.date(byAdding: .day, value: d, to: Date())!) }

let demo: [String: Any] = [
    "generated": now,
    "counts": ["open": 9, "working": 2, "naren": 3, "overdue": 0, "needs": 1, "done_today": 14],
    "runners": [
        ["id": "ultra", "state": "working", "text": "Working on “Quarterly budget review”", "since": now - 754, "app": true,
         "probe": ["open": "Quarterly budget review", "step": "Reading the Q3 statements", "generating": true]],
        ["id": "pro", "state": "waiting", "text": "Waiting on you", "app": true, "note": "“Launch checklist”: needs your sign-off on the release notes"],
        ["id": "local", "state": "working", "text": "Summarising 12 unread emails", "since": now - 38, "detail": "Qwen · on this Mac · no usage"],
    ],
    "attention": [["id": 4, "kind": "decision", "title": "Pick a venue for Saturday's dinner", "detail": "Three options ready"]],
    "actions": [["id": 7, "kind": "message.send", "summary": "Text Sam: “Running 10 minutes late”", "status": "approval"]],
    "tasks": [
        ["id": 41, "title": "Quarterly budget review", "for": "ultra", "status": "claimed", "holder": "ultra", "live": true, "progress": "Reading the Q3 statements", "due": day(1)],
        ["id": 44, "title": "Summarise unread email", "for": "local", "status": "claimed", "holder": "local", "live": true, "progress": "12 of 12 read", "due": day(0)],
        ["id": 38, "title": "Renew passport: book the appointment", "for": "naren", "status": "open", "due": day(1)],
        ["id": 39, "title": "Sign the lease renewal", "for": "naren", "status": "open", "due": day(3)],
        ["id": 40, "title": "Reply to the conference invite", "for": "naren", "status": "open", "due": day(9)],
        ["id": 42, "title": "Draft the launch announcement", "for": "pro", "status": "open", "due": day(2)],
        ["id": 43, "title": "Compare three flights to Lisbon", "for": "any", "status": "open", "due": day(4)],
        ["id": 45, "title": "Clean up the photo library", "for": "local", "status": "open", "due": day(6)],
        ["id": 46, "title": "Weekly reading digest", "for": "any", "status": "open", "due": day(7)],
        ["id": 36, "title": "Book a dentist cleaning", "for": "ultra", "status": "done", "result": "Booked Tue 9:30", "done_ts": now - 3600],
        ["id": 35, "title": "File the expense report", "for": "pro", "status": "done", "result": "Submitted, 6 receipts", "done_ts": now - 7200],
    ],
]

@MainActor
func render<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat, _ out: String) {
    let r = ImageRenderer(content: v.frame(width: w, height: h).background(Color.white).environment(\.colorScheme, .light).environment(\.still, true))
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("FAILED", out); return }
    try! png.write(to: URL(fileURLWithPath: out))
    print("wrote", out)
}

/// The Bridge window's night-room sidebar, drawn to match App/ShellDS.swift for the full-window shot.
struct SidebarShot: View {
    let rows: [(String, String, String?)] = [("square.grid.2x2", "Command", nil), ("list.bullet", "Board", "9"), ("bell", "Needs You", "5"), ("bubble.left", "Qwen", nil),
                                             ("", "FEEDS", nil), ("calendar", "Calendar", nil), ("checklist", "Reminders", nil), ("message", "Messages", "2"), ("envelope", "Mail", "12"),
                                             ("", "CONTROL", nil), ("square.stack.3d.up", "Apps", nil), ("lock", "Vault", nil), ("waveform.path.ecg", "Health", nil), ("slider.horizontal.3", "Settings", nil)]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                HStack(alignment: .center, spacing: 3) {
                    Capsule().fill(D.ultra).frame(width: 4, height: 9); Capsule().fill(D.pro).frame(width: 4, height: 14); Capsule().fill(D.mac).frame(width: 4, height: 20)
                }
                (Text("Bridge").foregroundColor(.white) + Text(".").foregroundColor(D.red)).font(D.display(24)).tracking(-1.2)
            }.padding(.horizontal, 8).padding(.top, 40).padding(.bottom, 12)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if r.0.isEmpty {
                    Text(r.1).font(D.a(11.5, 700, width: 112)).tracking(0.9).foregroundStyle(D.nightQuiet).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: r.0).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
                        Text(r.1).font(D.a(15, i == 0 ? 600 : 400))
                        Spacer()
                        if let c = r.2 { Text(c).font(D.a(13, 700)).foregroundStyle(.white).padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22).background(r.1 == "Needs You" ? D.red : Color(white: 0.2)) }
                    }
                    .foregroundStyle(i == 0 ? Color.white : D.nightQuiet)
                    .padding(.horizontal, 8).frame(height: 38)
                    .background(i == 0 ? Color.white.opacity(0.08) : Color.clear)
                    .overlay(alignment: .leading) { Rectangle().fill(i == 0 ? D.red : Color.clear).frame(width: 3) }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10).frame(width: 240).frame(maxHeight: .infinity).background(Color.black)
    }
}

@main
struct Shots {
    @MainActor static func main() {
        _ = NSApplication.shared
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, .process, nil)
        let outDir = CommandLine.arguments[2]
        let data = try! JSONSerialization.data(withJSONObject: demo)
        let snap = try! JSONDecoder().decode(Snap.self, from: data)
        func store(_ tab: Store.Tab) -> Store { let s = Store(backend: DemoBackend(snap)); s.tab = tab; return s }
        for (t, name) in [(Store.Tab.now, "phone-now"), (.needs, "phone-needs"), (.board, "phone-board")] {
            render(CompanionRoot().environmentObject(store(t)), 430, 932, "\(outDir)/\(name).png")
        }
        render(CompanionRoot().environmentObject(store(.needs)), 1000, 760, "\(outDir)/phone-unfolded.png")
        render(HStack(spacing: 0) { SidebarShot(); DeskCommand() }.environmentObject(store(.now)), 1440, 960, "\(outDir)/mac-command.png")
        render(DeskCommand().environmentObject(store(.now)), 1180, 960, "\(outDir)/mac-desk.png")
    }
}
