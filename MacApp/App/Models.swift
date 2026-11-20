import Foundation

// What the engine writes to snapshot.json once a second. Everything optional that could ever be missing,
// so one odd field never blanks the whole app.
struct Snapshot: Decodable {
    var v: String?
    var generated: Double
    var runners: [Runner]
    var tasks: [BTask]
    var counts: Counts
    var attention: [Attention]
    var actions: [BAction]
    var events: [BEvent]
    var feeds: [String: Feed]
    var health: [Health]
    var settings: [String: String]
    var apps: [AppInfo]?
    var vault: VaultIndex?
    var alarms: [Alarm]?
}

struct Runner: Decodable, Identifiable {
    var id: String
    var name: String
    var detail: String?
    var state: String
    var text: String
    var source: String?
    var holding: [Int]?
    var cpu: Double?
    var app: Bool?
    var note: String?
    var seen: Double?
    var since: Double?
    var probe: RunnerProbe?
}

struct RunnerProbe: Decodable {
    var open: String?
    var running: [String]?
    var generating: Bool?
    var step: String?
}

struct BTask: Decodable, Identifiable, Hashable {
    var id: Int
    var title: String
    var forWho: String
    var status: String
    var holder: String?
    var live: Bool
    var hb: Double?
    var due: String?
    var overdue: Bool
    var result: String?
    var note: String?
    var project: String?
    var url: String?
    var location: String?
    var progress: String?
    var created: Double?
    var by: String?
    var kind: String?
    var body: String?
    var doneTs: Double?
    var output: String?
    enum CodingKeys: String, CodingKey {
        case id, title, status, holder, live, hb, due, overdue, result, note, project, url, location, progress, created, by, kind, body, output
        case forWho = "for"
        case doneTs = "done_ts"
    }
    var isDone: Bool { status == "done" }
}

struct Counts: Decodable {
    var open: Int
    var working: Int
    var naren: Int
    var parked: Int
    var overdue: Int
    var needs: Int
    var doneToday: Int
    enum CodingKeys: String, CodingKey { case open, working, naren, parked, overdue, needs; case doneToday = "done_today" }
}

struct Attention: Decodable, Identifiable {
    var id: Int
    var ts: Double
    var actor: String?
    var kind: String
    var title: String
    var detail: String?
    var url: String?
    var due: String?
    var task: Int?
}

struct BAction: Decodable, Identifiable {
    var id: Int
    var ts: Double
    var actor: String?
    var kind: String
    var summary: String
    var status: String
    var result: String?
    var exec: String?
    var task: Int?
    var payload: [String: String]
}

struct BEvent: Decodable, Identifiable {
    var id: Int
    var ts: Double
    var actor: String?
    var type: String
    var text: String
    var task: Int?
}

struct Feed: Decodable {
    var asOf: Double?
    var ok: Bool
    var detail: String?
    var count: Int
    var fresh: Bool
    var by: String?
    var items: [FeedItem]
    enum CodingKeys: String, CodingKey { case ok, detail, count, fresh, by, items; case asOf = "as_of" }
}

struct MsgLine: Decodable, Hashable {
    var ts: Double?
    var me: Bool
    var who: String
    var text: String
}

struct FeedItem: Decodable, Identifiable {
    var id: String
    var ts: Double?
    var end: Double?
    var title: String
    var sub: String?
    var detail: String?
    var tag: String?
    var unread: Int?
    var flag: Bool?
    var allday: Bool?
    var lines: [MsgLine]?
}

struct Health: Decodable, Identifiable {
    var name: String
    var status: String
    var detail: String
    var ts: Double?
    var id: String { name }
}

struct AppInfo: Decodable, Identifiable {
    var id: String
    var name: String
    var path: String
    var installed: Bool
    var running: Bool
    var cpu: Double
    var mem: Int
    var version: String
    var note: String
}

struct VaultIndex: Decodable {
    var count: Int
    var items: [VaultItem]
}

struct VaultItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var url: String?
    var host: String?
    var username: String?
    var hasOtp: Int?
    var hasNotes: Int?
    enum CodingKeys: String, CodingKey { case id, title, url, host, username; case hasOtp = "has_otp"; case hasNotes = "has_notes" }
}

struct Alarm: Decodable, Identifiable {
    var id: String
    var time: String
    var label: String
    var enabled: Bool
    var source: String
    var `repeat`: String?
}

func ago(_ t: Double?) -> String {
    guard let t, t > 0 else { return "never" }
    let s = max(0, Date().timeIntervalSince1970 - t)
    if s < 5 { return "just now" }
    if s < 90 { return "\(Int(s)) s ago" }
    let m = s / 60
    if m < 90 { return "\(Int(m)) min ago" }
    let h = m / 60
    if h < 36 { return "\(Int(h)) h ago" }
    return "\(Int(h / 24)) d ago"
}

func clock(_ t: Double?, _ fmt: String = "MMM d · h:mm a") -> String {
    guard let t, t > 0 else { return "" }
    let f = DateFormatter()
    f.dateFormat = fmt
    return f.string(from: Date(timeIntervalSince1970: t))
}

func dueText(_ d: String?) -> String {
    guard let d, d.count == 10 else { return "" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    guard let date = f.date(from: d) else { return d }
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day ?? 0
    if days == 0 { return "today" }
    if days == 1 { return "tomorrow" }
    if days < 0 { return "\(-days) d overdue" }
    if days < 7 { f.dateFormat = "EEE"; return f.string(from: date) }
    f.dateFormat = "MMM d"
    return f.string(from: date)
}
