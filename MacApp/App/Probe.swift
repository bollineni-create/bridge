import AppKit
import ApplicationServices

/// Both accounts run from the same signed Claude.app. Ultra uses the default profile; Pro is the instance started on the
/// Duplex profile folder by /Applications/Claude Pro.app. So a runner is found by its profile argument, never by app path alone.
enum ClaudeApps {
    static let claude = "/Applications/Claude.app"
    static let pro = "/Applications/Claude Pro.app"       // the launcher, and the path Bridge uses to mean "the Pro runner"
    static let proMark = "Duplex/claude-2/data"

    static func args(_ pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buf.prefix(size).map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
    }

    /// The running app for a runner path. Any other path is matched the ordinary way.
    static func running(_ path: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        guard path == pro || path == claude else { return apps.first { $0.bundleURL?.path == path } }
        let wantPro = path == pro
        return apps.first { $0.bundleURL?.path == claude && $0.activationPolicy == .regular && args($0.processIdentifier).contains(proMark) == wantPro }
    }

    static func isFront(_ path: String) -> Bool {
        guard let f = NSWorkspace.shared.frontmostApplication, let r = running(path) else { return false }
        return f.processIdentifier == r.processIdentifier
    }
}

/// Reads what a Claude window is really showing through the Accessibility tree: the open chat's title and whether a reply is streaming.
enum AppProbe {
    static var enabled: Set<pid_t> = []
    static var lastSet: [String: String] = [:]
    static var thin: Set<String> = []      // apps whose tree stayed empty after the first switch
    static var thinCount: [String: Int] = [:]

    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    static func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
    static func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    static func app(_ path: String) -> NSRunningApplication? {
        ClaudeApps.running(path)
    }

    static func root(_ path: String) -> AXUIElement? {
        guard AXIsProcessTrusted(), let a = app(path) else { return nil }
        let el = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.5)
        if !enabled.contains(a.processIdentifier) {
            let r1 = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var r2 = AXError.success
            if r1 != .success || thin.contains(path) { r2 = AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
            lastSet[path] = "manual=\(r1.rawValue) enhanced=\(r2.rawValue)"
            if r1 == .success || r2 == .success { enabled.insert(a.processIdentifier) }
        }
        return el
    }

    /// Debug dump: structure only (roles, button names, headings, text lengths), no message text.
    static func dump(_ path: String) -> String {
        guard let r = root(path) else { return "no access or app not running (trusted=\(AXIsProcessTrusted()))" }
        var out: [String] = []
        var count = 0
        func walk(_ e: AXUIElement, _ d: Int) {
            if count > 6000 || d > 60 { return }
            count += 1
            let role = str(e, kAXRoleAttribute)
            let title = str(e, kAXTitleAttribute), desc = str(e, kAXDescriptionAttribute)
            let val = (attr(e, kAXValueAttribute) as? String) ?? ""
            let sub = str(e, kAXSubroleAttribute)
            if ["AXWindow", "AXButton", "AXHeading", "AXLink", "AXTextArea", "AXPopUpButton", "AXProgressIndicator", "AXBusyIndicator"].contains(role) || role == "AXStaticText" && d < 200 {
                let shown = role == "AXStaticText" ? "len=\(val.count) \(val.prefix(40))" : "t=\(title.prefix(70)) d=\(desc.prefix(70)) v=\(role == "AXTextArea" ? "len=\(val.count)" : String(val.prefix(40)))"
                out.append(String(repeating: " ", count: min(d, 30)) + "\(role) \(sub) \(shown)")
            }
            for k in kids(e) { walk(k, d + 1) }
        }
        for w in (attr(r, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
        return "nodes=\(count) set=\(lastSet[path] ?? "-")\n" + out.joined(separator: "\n")
    }

    /// What the window shows right now. Titles only; never message text.
    static func read(_ path: String) -> [String: Any]? {
        guard let r = root(path) else { return nil }
        var running: [String] = [], more: [String] = []
        var generating = false, step = "", model = "", count = 0
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXChildrenAttribute] as CFArray
        func walk(_ e: AXUIElement, _ d: Int) {
            if count > 5000 || d > 70 { return }
            count += 1
            var vals: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, names, [], &vals) == .success, let v = vals as? [AnyObject], v.count == 3 else { return }
            let role = v[0] as? String ?? "", title = v[1] as? String ?? ""
            if role == "AXButton" {
                if title == "Stop response" { generating = true }
                else if title.hasSuffix(" Running") { running.append(String(title.dropLast(8))) }
                else if title.hasPrefix("Using ") { step = title }
            } else if role == "AXPopUpButton" {
                if title.hasPrefix("More options for ") { more.append(String(title.dropFirst(17))) }
                else if title.hasPrefix("Model: ") { model = String(title.dropFirst(7)) }
            }
            for k in (v[2] as? [AXUIElement]) ?? [] { walk(k, d + 1) }
        }
        let wins = (attr(r, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in wins { walk(w, 0) }
        var open = ""
        if let last = more.last, more.filter({ $0 == last }).count >= 2 { open = last }
        if !generating { step = "" }
        if step.hasSuffix(" running") { step = String(step.dropLast(8)) }
        if let c = step.range(of: ": ") , step.count > 80 { step = String(step[..<c.lowerBound]) }
        if count <= 40, !wins.isEmpty, let a = app(path) {      // tree still empty: try the stronger switch once
            thinCount[path, default: 0] += 1
            if thinCount[path] == 3 { thin.insert(path); enabled.remove(a.processIdentifier) }
        } else { thinCount[path] = 0 }
        return ["window": count > 40, "open": open, "running": running, "generating": generating, "step": String(step.prefix(90)), "model": model]
    }

    /// Every (role, title) under the app, for before/after comparisons. Titles only.
    static func flat(_ path: String, limit: Int = 8000) -> [(AXUIElement, String, String)] {
        guard let r = root(path) else { return [] }
        var out: [(AXUIElement, String, String)] = []
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXChildrenAttribute, kAXDescriptionAttribute] as CFArray
        func walk(_ e: AXUIElement, _ d: Int) {
            if out.count > limit || d > 80 { return }
            var vals: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, names, [], &vals) == .success, let v = vals as? [AnyObject], v.count == 4 else { return }
            let role = v[0] as? String ?? "", t = (v[1] as? String ?? ""), dsc = v[3] as? String ?? ""
            out.append((e, role, t.isEmpty ? dsc : t))
            for k in (v[2] as? [AXUIElement]) ?? [] { walk(k, d + 1) }
        }
        // everything the app shows except its menu bar (Apple menu, Recent Items, Force Quit… must never match a model or effort name);
        // submenus such as "More models" open as their own pop-ups beside the window
        for k in kids(r) where str(k, kAXRoleAttribute) != "AXMenuBar" { walk(k, 0) }
        return out
    }

    /// The composer's model picker ("Model: Opus 5.5 Medium").
    static func modelPicker(_ path: String) -> (AXUIElement, String)? {
        flat(path).last { $0.1 == "AXPopUpButton" && $0.2.hasPrefix("Model: ") }.map { ($0.0, $0.2) }
    }

    static func escape(_ path: String) {
        guard let a = app(path) else { return }
        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(a.processIdentifier) }
    }

    /// Test hook: open the model picker, list what appears (role + title), close it again.
    static func modelMenuDump(_ path: String) -> String {
        guard let (pick, title) = modelPicker(path) else { return "no model picker" }
        let before = Set(flat(path).map { "\($0.1)|\($0.2)" })
        AXUIElementPerformAction(pick, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.9)
        let after = flat(path)
        let newItems = after.filter { !before.contains("\($0.1)|\($0.2)") }
        var lines = newItems.map { "\($0.1) \($0.2)" }
        escape(path)
        Thread.sleep(forTimeInterval: 0.4)
        // one level down: each submenu-looking item, opened on its own
        for sub in newItems where sub.1 == "AXMenuItem" && (sub.2.hasPrefix("Effort") || sub.2.hasPrefix("More models")) {
            guard let (p2, _) = modelPicker(path) else { break }
            AXUIElementPerformAction(p2, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.8)
            let open1 = flat(path)
            let mid = Set(open1.map { "\($0.1)|\($0.2)" })
            guard let item = open1.first(where: { $0.1 == "AXMenuItem" && $0.2 == sub.2 }) else { escape(path); continue }
            AXUIElementPerformAction(item.0, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.8)
            let deeper = flat(path).filter { !mid.contains("\($0.1)|\($0.2)") }.map { "   \($0.1) \($0.2)" }
            lines.append("-- inside \(sub.2):")
            lines += deeper
            escape(path); Thread.sleep(forTimeInterval: 0.3); escape(path); Thread.sleep(forTimeInterval: 0.4)
        }
        return "picker: \(title)\n" + lines.joined(separator: "\n") + "\nafter: \(modelPicker(path)?.1 ?? "?")"
    }

    /// Open the picker, then press the first menu item whose title starts with `prefix` (optionally one level down, under `via`).
    @discardableResult
    static func pickMenu(_ path: String, via: String?, prefix: String) -> Bool {
        guard let (pick, _) = modelPicker(path) else { return false }
        AXUIElementPerformAction(pick, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.7)
        var items = flat(path).filter { $0.1 == "AXMenuItem" }
        if let via {
            guard let sub = items.first(where: { $0.2.hasPrefix(via) }) else { escape(path); return false }
            AXUIElementPerformAction(sub.0, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.7)
            items = flat(path).filter { $0.1 == "AXMenuItem" }
        }
        guard let hit = items.last(where: { $0.2 == prefix || $0.2.hasPrefix(prefix + " ") }) else { escape(path); escape(path); return false }
        AXUIElementPerformAction(hit.0, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.7)
        if modelPicker(path).map({ _ in flat(path).contains { $0.1 == "AXMenuItem" } }) == true { escape(path); Thread.sleep(forTimeInterval: 0.3) }
        return true
    }

    /// Set the composer's model and effort ("Sonnet 5.5", "medium"). Never chooses Max on its own. Returns the picker title afterwards.
    static func setModel(_ path: String, model: String, effort: String) -> String {
        guard let (_, before) = modelPicker(path) else { return "no model picker" }
        let words = ["low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra", "extra": "Extra"]
        let eff = words[effort.lowercased()] ?? ""
        let now = String(before.dropFirst(7))                                   // "Opus 5.5 Medium"
        if !model.isEmpty, !now.hasPrefix(model + " ") {
            // the current/recommended model is on the first level; the rest are under "More models"
            if !pickMenu(path, via: nil, prefix: model) { pickMenu(path, via: "More models", prefix: model) }
        }
        if !eff.isEmpty, let cur = modelPicker(path)?.1, !cur.hasSuffix(" " + eff) {
            pickMenu(path, via: "Effort", prefix: eff)
        }
        return modelPicker(path)?.1 ?? "?"
    }

    /// Send a message without bringing the window forward: open the chat (or a new one), set model + effort, fill the box, press Send.
    /// Returns "ok: …", "limit: …" or "fail: …" (the engine falls back to keystrokes on fail).
    static func post(_ path: String, text: String, newChat: Bool, chat: String, model: String, effort: String) -> String {
        guard root(path) != nil else { return "fail: no access to the Claude window" }
        if !chat.isEmpty {
            let got = focusChat(path, chat)
            if got != chat { return "fail: could not open the chat \u{201C}\(chat)\u{201D} (\(got))" }
        } else if newChat {
            guard let new = flat(path).first(where: { $0.1 == "AXButton" && $0.2 == "New" }) else { return "fail: no New button" }
            AXUIElementPerformAction(new.0, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 1.5)
        }
        let pre = sendState(path)
        if let l = pre["limit"] as? String, !l.isEmpty { return "limit: \(l)" }
        if (pre["composer"] as? Int ?? 0) > 0 { return "fail: there is unsent text in the message box" }
        var picked = ""
        if !model.isEmpty || !effort.isEmpty { picked = setModel(path, model: model, effort: effort) }
        guard let box = flat(path).last(where: { $0.1 == "AXTextArea" && $0.2.hasPrefix("Write your prompt") })?.0 else { return "fail: no message box" }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(box, kAXValueAttribute as CFString, text as CFString)
        Thread.sleep(forTimeInterval: 0.5)
        var filled = (attr(box, kAXValueAttribute) as? String ?? "").count
        if filled < max(1, text.count * 8 / 10) {
            AXUIElementSetAttributeValue(box, kAXSelectedTextAttribute as CFString, text as CFString)
            Thread.sleep(forTimeInterval: 0.5)
            filled = (attr(box, kAXValueAttribute) as? String ?? "").count
        }
        if filled < max(1, text.count * 8 / 10) {
            AXUIElementSetAttributeValue(box, kAXValueAttribute as CFString, "" as CFString)
            return "fail: the message box did not take the text (\(filled)/\(text.count))"
        }
        guard let send = flat(path).last(where: { $0.1 == "AXButton" && $0.2 == "Send message" })?.0 else { return "fail: no Send button" }
        AXUIElementPerformAction(send, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 2.0)
        let post = sendState(path)
        if let l = post["limit"] as? String, !l.isEmpty { return "limit: \(l)" }
        if (post["composer"] as? Int ?? 0) > 0 && !(post["generating"] as? Bool ?? false) { return "fail: the message stayed in the box" }
        return "ok: sent\(picked.isEmpty ? "" : " · " + picked)"
    }

    /// Click the sidebar chat with this title, so a message lands in that exact chat. Returns the open chat's title afterwards.
    static func focusChat(_ path: String, _ title: String) -> String {
        guard let r = root(path) else { return "no access" }
        var target: AXUIElement?, count = 0
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXChildrenAttribute] as CFArray
        func walk(_ e: AXUIElement, _ d: Int) {
            if target != nil || count > 6000 || d > 70 { return }
            count += 1
            var vals: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, names, [], &vals) == .success, let v = vals as? [AnyObject], v.count == 3 else { return }
            let role = v[0] as? String ?? "", t = v[1] as? String ?? ""
            if (role == "AXButton" || role == "AXLink") && (t == title || t == title + " Running") { target = e; return }
            for k in (v[2] as? [AXUIElement]) ?? [] { walk(k, d + 1) }
        }
        for w in (attr(r, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
        guard let t = target else { return "not found" }
        AXUIElementPerformAction(t, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 1.2)
        return (read(path)?["open"] as? String) ?? ""
    }

    /// Everything the window shows: the open chat's conversation (in order), whether it is replying, the sessions marked Running,
    /// the recent chats in the sidebar, the current step and the model. Stays on this Mac (local database only).
    static func chatRead(_ path: String, maxChars: Int = 60000) -> [String: Any]? {
        guard let r = root(path) else { return nil }
        var items: [(String, String)] = []     // (role, text) in tree order
        var count = 0
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
        func walk(_ e: AXUIElement, _ d: Int) {
            if count > 20000 || d > 90 { return }
            count += 1
            var vals: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(e, names, [], &vals) == .success, let v = vals as? [AnyObject], v.count == 4 else { return }
            let role = v[0] as? String ?? "", title = v[1] as? String ?? "", value = v[2] as? String ?? ""
            switch role {
            case "AXStaticText": if !value.isEmpty { items.append(("t", value)) }
            case "AXHeading": items.append(("h", title))
            case "AXButton": items.append(("b", title))
            case "AXPopUpButton": items.append(("p", title))
            default: break
            }
            for k in (v[3] as? [AXUIElement]) ?? [] { walk(k, d + 1) }
        }
        let wins = (attr(r, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in wins { walk(w, 0) }
        var running: [String] = [], more: [String] = [], buttons = Set<String>(), generating = false, step = "", model = ""
        for (k, t) in items {
            if k == "b" {
                buttons.insert(t)
                if t == "Stop response" { generating = true }
                else if t.hasSuffix(" Running") { running.append(String(t.dropLast(8))) }
                else if t.hasPrefix("Using ") { step = t }
            } else if k == "p" {
                if t.hasPrefix("More options for ") { more.append(String(t.dropFirst(17))) }
                else if t.hasPrefix("Model: ") { model = String(t.dropFirst(7)) }
            }
        }
        var open = ""
        if let last = more.last, more.filter({ $0 == last }).count >= 2 { open = last }
        var recents: [String] = []
        for m in more where (buttons.contains(m) || buttons.contains(m + " Running")) && !recents.contains(m) && m != open { recents.append(m) }
        // the conversation: turns start at headings "You said: …" / "Claude responded: …"
        var turns: [[String: String]] = []
        var cur: [String: String]? = nil
        func flush() { if let c = cur, !(c["text"] ?? "").isEmpty { turns.append(c) }; cur = nil }
        for (k, t) in items {
            if k == "h" && t.hasPrefix("You said:") { flush(); cur = ["role": "the owner", "text": ""] }
            else if k == "h" && t.hasPrefix("Claude responded:") { flush(); cur = ["role": "Claude", "text": ""] }
            else if k == "h", cur != nil, !t.isEmpty, !t.hasPrefix("More options") { cur!["text"]! += "\n## " + t + "\n" }
            else if k == "t", cur != nil { cur!["text"]! += (cur!["text"]!.isEmpty || cur!["text"]!.hasSuffix("\n") ? "" : " ") + t }
            else if k == "b", cur != nil, t.hasPrefix("Used ") || t.hasPrefix("Using ") { cur!["text"]! += "\n[" + t + "]\n" }
        }
        flush()
        var total = 0, keep: [[String: String]] = []
        for t in turns.reversed() { total += (t["text"] ?? "").count; if total > maxChars && !keep.isEmpty { break }; keep.insert(t, at: 0) }
        if !generating { step = "" }
        if step.hasSuffix(" running") { step = String(step.dropLast(8)) }
        if let c = step.range(of: ": "), step.count > 80 { step = String(step[..<c.lowerBound]) }
        return ["window": count > 40, "open": open, "running": running, "generating": generating, "step": String(step.prefix(90)),
                "model": model, "recents": Array(recents.prefix(15)), "turns": keep, "turn_count": turns.count]
    }

    /// chatRead, with one more try when the tree came back empty: the first read after a Claude window starts (or after Bridge
    /// switches accessibility on for it) is thin, and the next slow refresh is minutes away.
    static func chatReadSettled(_ path: String) -> [String: Any]? {
        guard var r = chatRead(path) else { return nil }
        for _ in 0..<2 where (r["window"] as? Bool) != true {
            Thread.sleep(forTimeInterval: 1.2)
            if let again = chatRead(path) { r = again }
        }
        return r
    }

    /// After Bridge presses Return: is the message still sitting in the box? Counts and the usage-limit line only, never chat text.
    static func sendState(_ path: String) -> [String: Any] {
        var out: [String: Any] = ["nodes": 0]
        for attempt in 0..<3 {
            guard let r = root(path) else { return out }
            var count = 0, composer = 0, youSaid = 0, generating = false, limit = ""
            let names = [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
            func walk(_ e: AXUIElement, _ d: Int) {
                if count > 20000 || d > 90 { return }
                count += 1
                var vals: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(e, names, [], &vals) == .success, let v = vals as? [AnyObject], v.count == 4 else { return }
                let role = v[0] as? String ?? "", title = v[1] as? String ?? "", value = v[2] as? String ?? ""
                switch role {
                case "AXTextArea": composer = max(composer, value.trimmingCharacters(in: .whitespacesAndNewlines).count)
                case "AXStaticText": if limit.isEmpty, value.hasPrefix("Usage limit reached") { limit = String(value.prefix(120)) }
                case "AXButton": if title == "Stop response" { generating = true }
                case "AXHeading": if title.hasPrefix("You said:") { youSaid += 1 }
                default: break
                }
                for k in (v[3] as? [AXUIElement]) ?? [] { walk(k, d + 1) }
            }
            for w in (attr(r, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
            out = ["nodes": count, "composer": composer, "generating": generating, "you_said": youSaid, "limit": limit]
            if count > 40 { break }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.8) }      // the tree is thin on the first read after a window comes forward
        }
        return out
    }

    /// Mac idle time in seconds (no keyboard, mouse or trackpad input).
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
