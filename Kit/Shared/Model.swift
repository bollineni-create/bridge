import Foundation
import SwiftUI

// The board as Bridge's engine writes it (snapshot.json on the Mac, companion.json in iCloud).
// Every field optional: one odd field never blanks the app.
struct Snap: Decodable {
    var generated: Double?
    var runners: [Runner]?
    var tasks: [BTask]?
    var counts: Counts?
    var attention: [Attn]?
    var actions: [Act]?
}
struct Probe: Decodable { var open: String?; var step: String?; var generating: Bool?; var running: [String]? }
struct Runner: Decodable, Identifiable {
    var id: String
    var state: String?
    var text: String?
    var note: String?
    var detail: String?
    var since: Double?
    var app: Bool?
    var probe: Probe?
}
struct BTask: Decodable, Identifiable, Hashable {
    var id: Int
    var title: String
    var forWho: String?
    var status: String?
    var holder: String?
    var live: Bool?
    var due: String?
    var overdue: Bool?
    var result: String?
    var output: String?
    var progress: String?
    var doneTs: Double?
    enum CodingKeys: String, CodingKey { case id, title, status, holder, live, due, overdue, result, output, progress; case forWho = "for"; case doneTs = "done_ts" }
    var isDone: Bool { status == "done" }
}
struct Counts: Decodable {
    var open: Int?; var working: Int?; var naren: Int?; var overdue: Int?; var needs: Int?; var doneToday: Int?
    enum CodingKeys: String, CodingKey { case open, working, naren, overdue, needs; case doneToday = "done_today" }
}
struct Attn: Decodable, Identifiable { var id: Int; var kind: String?; var title: String; var detail: String?; var url: String?; var due: String?; var task: Int? }
struct Act: Decodable, Identifiable { var id: Int; var kind: String?; var summary: String?; var status: String? }
