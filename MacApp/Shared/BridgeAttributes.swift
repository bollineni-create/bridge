import Foundation
import ActivityKit

struct BridgeAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var ultra: String       // working | holding | idle | away | offline | unknown
        var pro: String
        var local: String       // working | ready | idle | offline | unknown
        var openCount: Int
        var needs: Int
        var working: [String]   // "Pro · T3 Credit re-freeze"
        var waiting: [String]   // "T2 CFA scholarship · due 11/22"
        var updated: Date
        var done: Int = 0          // finished today
        var mine: Int = 0          // waiting on the owner (needs + tasks only he can do)
        var ultraOn: String = ""   // "T39 test": what each runner holds right now
        var proOn: String = ""
        var localOn: String = ""
        var ultraSince: Date? = nil   // when each runner started working; the island counts up from it
        var proSince: Date? = nil
        var localSince: Date? = nil
        // Current-task progress (Nov 21): what the island's fill tracks, and the flash when it finishes.
        var focus: String = ""        // "T110", or the runner code when it works in a chat with no board task
        var focusPct: Double = -1     // 0...1; -1 = nothing running
        var justDone: String = ""     // "T110 done" for ~12 s after it finishes
    }
}
