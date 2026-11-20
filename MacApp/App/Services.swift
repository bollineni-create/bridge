import Foundation
import AppKit
import EventKit
import CoreLocation
import LocalAuthentication
import CryptoKit
import UserNotifications
import ApplicationServices

func jsonString(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

// MARK: Calendar + Reminders through EventKit (no AppleScript, so nothing to hang)
final class Kit {
    let store = EKEventStore()
    var calOK = false
    var remOK = false

    var calWhy = ""
    var remWhy = ""

    static func statusName(_ t: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: t) {
        case .notDetermined: return "not asked yet"
        case .restricted: return "restricted by a profile"
        case .denied: return "turned off"
        case .fullAccess: return "full access"
        case .writeOnly: return "write-only"
        default: return "limited"
        }
    }

    func request() async {
        do { calOK = try await store.requestFullAccessToEvents() } catch { calWhy = error.localizedDescription }
        do { remOK = try await store.requestFullAccessToReminders() } catch { remWhy = error.localizedDescription }
        refresh()
    }

    /// Picks up a permission granted later in System Settings without a relaunch.
    func refresh() {
        calOK = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remOK = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func calendarPayload() -> String {
        refresh()
        guard calOK else { return jsonString(["ok": false, "detail": "Calendar is \(Kit.statusName(.event)) for Bridge. Turn it on in System Settings > Privacy & Security > Calendars. \(calWhy)"]) }
        let now = Date()
        let pred = store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: now.addingTimeInterval(45 * 86400), calendars: nil)
        var items: [[String: Any]] = []
        for e in store.events(matching: pred).prefix(400) {
            let start = e.startDate.timeIntervalSince1970
            var it: [String: Any] = ["id": "\(e.eventIdentifier ?? UUID().uuidString)-\(Int(start))", "ts": start, "end": e.endDate.timeIntervalSince1970,
                                     "title": e.title ?? "(no title)", "tag": e.calendar.title, "allday": e.isAllDay]
            if let l = e.location, !l.isEmpty { it["detail"] = l }
            items.append(it)
        }
        return jsonString(["ok": true, "items": items])
    }

    func openReminders() async -> [EKReminder] {
        await withCheckedContinuation { c in
            store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { c.resume(returning: $0 ?? []) }
        }
    }

    func remindersPayload() async -> String {
        guard remOK else { return jsonString(["ok": false, "detail": "Reminders is \(Kit.statusName(.reminder)) for Bridge. Turn it on in System Settings > Privacy & Security > Reminders. \(remWhy)"]) }
        var items: [[String: Any]] = []
        for r in await openReminders() where r.calendar.title.caseInsensitiveCompare("ARCHIVE") != .orderedSame {
            var it: [String: Any] = ["id": r.calendarItemIdentifier, "title": r.title ?? "(no title)", "tag": r.calendar.title, "flag": r.priority > 0]
            if let dc = r.dueDateComponents, let d = Calendar.current.date(from: dc) { it["ts"] = d.timeIntervalSince1970 }
            if let n = r.notes, !n.isEmpty { it["sub"] = String(n.prefix(300)) }
            items.append(it)
        }
        return jsonString(["ok": true, "items": items])
    }

    func list(_ name: String) -> EKCalendar? {
        store.calendars(for: .reminder).first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }

    func match(_ q: String) async -> (EKReminder?, String) {
        let all = await openReminders()
        if let exact = all.first(where: { $0.calendarItemIdentifier == q || (q.count >= 6 && $0.calendarItemIdentifier.uppercased().hasPrefix(q.uppercased())) }) { return (exact, "") }   // full id, or the short id the feed prints
        let live = all.filter { $0.calendar.title.caseInsensitiveCompare("ARCHIVE") != .orderedSame }
        let same = live.filter { ($0.title ?? "").caseInsensitiveCompare(q) == .orderedSame }
        if same.count == 1 { return (same[0], "") }      // an exact title beats a longer one that merely starts the same
        let hits = live.filter { ($0.title ?? "").lowercased().hasPrefix(q.lowercased()) }
        if hits.count == 1 { return (hits[0], "") }
        return (nil, hits.isEmpty ? "no open reminder starts with “\(q)”" : "\(hits.count) reminders start with “\(q)”; be more specific")
    }

    func perform(_ a: BAction) async -> (Bool, String) {
        let p = a.payload
        do {
            switch a.kind {
            case "reminder.add":
                guard remOK else { return (false, "Bridge has no Reminders access") }
                let name = (p["list"] ?? "").isEmpty ? "Claude" : p["list"]!
                guard let cal = list(name) else { return (false, "there is no Reminders list named “\(name)”") }
                let r = EKReminder(eventStore: store)
                r.title = p["title"] ?? ""
                r.calendar = cal
                if let n = p["notes"], !n.isEmpty { r.notes = n }
                var when = ""
                if let ds = p["due"], let t = Double(ds) {
                    let d = Date(timeIntervalSince1970: t)
                    r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                    r.addAlarm(EKAlarm(absoluteDate: d))
                    when = " due " + clock(t)
                }
                try store.save(r, commit: true)
                return (true, "reminder created in \(cal.title)\(when) (id \(r.calendarItemIdentifier.prefix(8)))")
            case "reminder.complete", "reminder.archive":
                guard remOK else { return (false, "Bridge has no Reminders access") }
                let (found, why) = await match(p["match"] ?? "")
                guard let r = found else { return (false, why) }
                if a.kind == "reminder.complete" {
                    r.isCompleted = true
                    try store.save(r, commit: true)
                    return (true, "completed “\(r.title ?? "")”")
                }
                guard let arc = list("ARCHIVE") else { return (false, "there is no Reminders list named ARCHIVE") }
                r.calendar = arc
                try store.save(r, commit: true)
                return (true, "moved “\(r.title ?? "")” to ARCHIVE")
            case "event.add":
                guard calOK else { return (false, "Bridge has no Calendar access") }
                guard let s = Double(p["start"] ?? ""), let e = Double(p["end"] ?? "") else { return (false, "bad start or end time") }
                let ev = EKEvent(eventStore: store)
                let want = p["calendar"] ?? ""
                if want.isEmpty {
                    guard let d = store.defaultCalendarForNewEvents else { return (false, "no default calendar") }
                    ev.calendar = d
                } else {
                    guard let c = store.calendars(for: .event).first(where: { $0.title.caseInsensitiveCompare(want) == .orderedSame && $0.allowsContentModifications }) else {
                        return (false, "there is no editable calendar named “\(want)”")
                    }
                    ev.calendar = c
                }
                ev.title = p["title"] ?? ""
                ev.startDate = Date(timeIntervalSince1970: s)
                ev.endDate = Date(timeIntervalSince1970: e)
                ev.isAllDay = p["allday"] == "1"
                if let l = p["location"], !l.isEmpty { ev.location = l }
                if let n = p["notes"], !n.isEmpty { ev.notes = n }
                try store.save(ev, span: .thisEvent, commit: true)
                return (true, "event created on \(ev.calendar.title): \(clock(s))")
            case "event.remove":   // the engine only queues this for events Bridge added itself
                guard calOK else { return (false, "Bridge has no Calendar access") }
                guard let s = Double(p["start"] ?? "") else { return (false, "bad start time") }
                let day = Date(timeIntervalSince1970: s)
                let pred = store.predicateForEvents(withStart: day.addingTimeInterval(-60), end: day.addingTimeInterval(86400), calendars: nil)
                let hits = store.events(matching: pred).filter { $0.title == (p["title"] ?? "") && abs($0.startDate.timeIntervalSince1970 - s) < 60 }
                guard let ev = hits.first else { return (false, "no event with that title and start time") }
                let added = Int(p["count"] ?? "1") ?? 1       // how many of these Bridge itself added
                guard hits.count <= added else { return (false, "\(hits.count) events match but Bridge added only \(added); not removing any") }
                let cal = ev.calendar.title
                for h in hits { try store.remove(h, span: .thisEvent, commit: false) }
                try store.commit()
                return (true, "removed \(hits.count == 1 ? "" : "\(hits.count) × ")“\(p["title"] ?? "")” from \(cal)")
            default:
                return (false, "no executor for \(a.kind)")
            }
        } catch {
            return (false, "EventKit error: \(error.localizedDescription)")
        }
    }
}

// MARK: Location
final class Locator: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    let geo = CLGeocoder()
    var last = ""
    var onUpdate: ((String) -> Void)?

    func start(_ cb: @escaping (String) -> Void) {
        onUpdate = cb
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 150
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func push(_ s: String) { last = s; onUpdate?(s) }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        let coord = String(format: "%.4f, %.4f · ±%.0f m", l.coordinate.latitude, l.coordinate.longitude, l.horizontalAccuracy)
        let fix = l.timestamp.timeIntervalSince1970
        geo.reverseGeocodeLocation(l) { marks, _ in
            let pm = marks?.first
            let place = [pm?.locality, pm?.administrativeArea].compactMap { $0 }.joined(separator: ", ")
            let street = [pm?.subThoroughfare, pm?.thoroughfare].compactMap { $0 }.joined(separator: " ")
            let item: [String: Any] = ["id": "here", "ts": fix, "title": place.isEmpty ? "This Mac" : place, "sub": coord, "detail": street, "tag": pm?.country ?? ""]
            self.push(jsonString(["ok": true, "items": [item]]))
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        if last.isEmpty { push(jsonString(["ok": false, "detail": "No location fix yet (\(error.localizedDescription))"])) }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .denied || m.authorizationStatus == .restricted {
            push(jsonString(["ok": false, "detail": "Location is off for Bridge (System Settings > Privacy & Security > Location Services)"]))
        } else {
            m.startUpdatingLocation()
        }
    }
}

// MARK: Notifications
enum Notifier {
    static func request() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    static func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: Vault. Secrets live in the login Keychain, readable by Bridge only. The engine gets names, sites and usernames; never a secret.
final class Vault {
    let service = "com.naren.bridge.vault"
    var unlockedUntil = Date.distantPast

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    func save(_ id: String, _ secret: [String: String], label: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: secret) else { return false }
        SecItemDelete(query(id) as CFDictionary)
        var add = query(id)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Bridge Vault: " + label
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func load(_ id: String) -> [String: String]? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: String]
    }

    func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }

    func unlock(_ reason: String) async -> Bool {
        if Date() < unlockedUntil { return true }
        let ctx = LAContext()
        guard let ok = try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason), ok else { return false }
        unlockedUntil = Date().addingTimeInterval(300)
        return true
    }

    func copy(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if pb.changeCount == count { pb.clearContents() } }
    }

    func type(_ s: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for unit in Array(s.utf16) {
            var c = unit
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) {
                    e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                    e.post(tap: .cghidEventTap)
                }
            }
            usleep(9000)
        }
    }

    func key(_ code: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(120000)
    }

    /// A runner asked for a login. The secret goes from the Keychain straight into the field or the clipboard; the result text never contains it.
    func fill(_ p: [String: String]) -> (Bool, String) {
        guard let id = p["id"], let sec = load(id) else { return (false, "that login is not in the Keychain (re-import the CSV)") }
        let field = p["field"] ?? "both"
        let user = p["username"] ?? ""
        let pass = sec["p"] ?? ""
        var code = ""
        if field == "otp" {
            guard let o = sec["o"], let c = Vault.totp(o) else { return (false, "no one-time code is stored for this login") }
            code = c
        }
        let canType = AXIsProcessTrusted() && !NSApp.isActive
        if canType {
            switch field {
            case "username": type(user)
            case "password": type(pass)
            case "otp": type(code)
            default: type(user); key(48); type(pass)
            }
            return (true, "typed \(field == "both" ? "username and password" : field) into the front window")
        }
        copy(field == "username" ? user : (field == "otp" ? code : pass))
        let what = field == "username" ? "username" : (field == "otp" ? "one-time code" : "password")
        return (true, "\(what) is on the clipboard for 60 s; paste with Cmd+V" + (field == "both" ? " (username: \(user))" : ""))
    }

    // CSV as exported by Passwords, Chrome, 1Password and most managers (quoted fields, commas and newlines inside quotes)
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.append(ch) }
            i += 1
        }
        row.append(field)
        if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        return rows
    }

    struct Imported { var item: VaultItem; var secret: [String: String] }

    static func importCSV(_ url: URL) -> ([Imported], String) {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return ([], "could not read the file") }
        let rows = parseCSV(text)
        guard rows.count > 1 else { return ([], "the file has no rows") }
        let head = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "\u{feff}", with: "") }
        func col(_ names: [String]) -> Int? { head.firstIndex { names.contains($0) } }
        guard let pc = col(["password", "login_password", "pass"]) else { return ([], "no Password column found (columns: \(head.joined(separator: ", ")))") }
        let tc = col(["title", "name", "account"]), uc = col(["url", "website", "login_uri", "web site"])
        let nc = col(["username", "login", "login_username", "user name", "email"]), oc = col(["otpauth", "totp", "otp", "login_totp"]), mc = col(["notes", "note", "comments", "extra"])
        var out: [Imported] = []
        for r in rows.dropFirst() {
            func get(_ i: Int?) -> String { guard let i, i < r.count else { return "" }; return r[i].trimmingCharacters(in: .whitespacesAndNewlines) }
            let pass = get(pc)
            if pass.isEmpty { continue }
            let url = get(uc)
            var title = get(tc)
            if title.isEmpty { title = URL(string: url)?.host ?? url }
            if title.isEmpty { title = "Untitled" }
            var secret = ["p": pass]
            if !get(oc).isEmpty { secret["o"] = get(oc) }
            if !get(mc).isEmpty { secret["n"] = get(mc) }
            let item = VaultItem(id: UUID().uuidString, title: title, url: url, host: nil, username: get(nc), hasOtp: get(oc).isEmpty ? 0 : 1, hasNotes: get(mc).isEmpty ? 0 : 1)
            out.append(Imported(item: item, secret: secret))
        }
        return (out, out.isEmpty ? "no rows with a password" : "")
    }

    static func base32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && ch != " " && ch != "-" {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xff)); bits -= 8 }
        }
        return out.isEmpty ? nil : out
    }

    static func totp(_ raw: String) -> String? {
        var secret = raw, digits = 6, period = 30.0
        if raw.lowercased().hasPrefix("otpauth://"), let c = URLComponents(string: raw) {
            let q = c.queryItems ?? []
            secret = q.first { $0.name.lowercased() == "secret" }?.value ?? ""
            digits = Int(q.first { $0.name.lowercased() == "digits" }?.value ?? "6") ?? 6
            period = Double(q.first { $0.name.lowercased() == "period" }?.value ?? "30") ?? 30
        }
        guard let key = base32(secret) else { return nil }
        var counter = UInt64(Date().timeIntervalSince1970 / period).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
        let o = Int(mac[19] & 0x0f)
        let bin = (UInt32(mac[o] & 0x7f) << 24) | (UInt32(mac[o + 1]) << 16) | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
        var mod: UInt32 = 1
        for _ in 0..<digits { mod *= 10 }
        let n = String(bin % mod)
        return String(repeating: "0", count: max(0, digits - n.count)) + n
    }
}
