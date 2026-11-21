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
            guard let new = flat(path, limit: 40000).first(where: { $0.1 == "AXButton" && $0.2 == "New" }) else { return "fail: no New button" }
            AXUIElementPerformAction(new.0, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 1.5)
        }
        let pre = sendState(path)
        if let l = pre["limit"] as? String, !l.isEmpty { return "limit: \(l)" }
        if (pre["composer"] as? Int ?? 0) > 0 {
            let boxes = flat(path, limit: 40000).filter { $0.1 == "AXTextArea" }
            let b = boxes.last(where: { $0.2.hasPrefix("Write your prompt") })?.0 ?? boxes.last?.0
            let v = b.flatMap { attr($0, kAXValueAttribute) as? String } ?? "x"
            if let b, v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { AXUIElementSetAttributeValue(b, kAXValueAttribute as CFString, "" as CFString) }
            else { return "fail: there is unsent text in the message box (\(v.count) characters; left untouched)" }      // his own draft: never overwrite it
        }
        var picked = ""
        if !model.isEmpty || !effort.isEmpty { picked = setModel(path, model: model, effort: effort) }
        // The composer's label differs by view (a chat says "Write your prompt to Claude", a new code session or project something else),
        // and a fresh chat can take a moment to draw it: prefer the known label, then any prompt-like box, then the last text area; wait up to 4 s.
        func findBox() -> AXUIElement? {
            let f = flat(path, limit: 40000).filter { $0.1 == "AXTextArea" }
            if let b = f.last(where: { $0.2.hasPrefix("Write your prompt") }) { return b.0 }
            let hints = ["prompt", "message", "reply", "help", "ask", "task", "describe"]
            if let b = f.last(where: { t in hints.contains { t.2.lowercased().contains($0) } }) { return b.0 }
            return f.last?.0
        }
        var found = findBox()
        for _ in 0..<8 where found == nil { Thread.sleep(forTimeInterval: 0.5); found = findBox() }
        guard var box = found else { return "fail: no message box" }
        // A fresh session redraws its composer just after it opens, which can wipe text set too early: find the box again and refill, up to 3 times.
        var filled = 0
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.8); if let b = findBox() { box = b } }
            AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(box, kAXValueAttribute as CFString, text as CFString)
            Thread.sleep(forTimeInterval: 0.5)
            filled = (attr(box, kAXValueAttribute) as? String ?? "").count
            if filled < max(1, text.count * 8 / 10) {
                AXUIElementSetAttributeValue(box, kAXSelectedTextAttribute as CFString, text as CFString)
                Thread.sleep(forTimeInterval: 0.5)
                filled = (attr(box, kAXValueAttribute) as? String ?? "").count
            }
            if filled >= max(1, text.count * 8 / 10) { break }
        }
        if filled < max(1, text.count * 8 / 10) {
            AXUIElementSetAttributeValue(box, kAXValueAttribute as CFString, "" as CFString)
            return "fail: the message box did not take the text (\(filled)/\(text.count))"
        }
        guard let send = (flat(path, limit: 40000).last(where: { $0.1 == "AXButton" && $0.2 == "Send message" })
                          ?? flat(path, limit: 40000).last(where: { $0.1 == "AXButton" && ["Send", "Submit", "Send prompt", "Start"].contains($0.2) }))?.0 else { return "fail: no Send button" }
        AXUIElementPerformAction(send, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 2.0)
        let post = sendState(path)
        if let l = post["limit"] as? String, !l.isEmpty { return "limit: \(l)" }
        if (post["composer"] as? Int ?? 0) > 0 && !(post["generating"] as? Bool ?? false) { return "fail: the message stayed in the box" }
        return "ok: sent\(picked.isEmpty ? "" : " · " + picked)"
    }

    /// Press the permission button the owner picked in Bridge Chat: open its chat if named, then press the last button with exactly that title.
    static func pressButton(_ path: String, chat: String, title: String) -> String {
        guard root(path) != nil else { return "fail: no access to the Claude window" }
        if !chat.isEmpty, (read(path)?["open"] as? String ?? "") != chat {
            let got = focusChat(path, chat)
            if got != chat { return "fail: could not open the chat \u{201C}\(chat)\u{201D} (\(got))" }
        }
        guard let b = flat(path, limit: 40000).last(where: { $0.1 == "AXButton" && $0.2 == title })?.0 else { return "fail: the \u{201C}\(title)\u{201D} button is no longer on screen" }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
        return "ok: pressed \(title)"
    }

    /// Click the sidebar chat with this title, so a message lands in that exact chat. Returns the open chat's title afterwards.
    static func focusChat(_ path: String, _ title: String) -> String {
        guard let r = root(path) else { return "no access" }
        var target: AXUIElement?, count = 0
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXChildrenAttribute] as CFArray
        func walk(_ e: AXUIElement, _ d: Int) {
            if target != nil || count > 40000 || d > 90 { return }
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
        // A permission card (Claude asking before it uses a tool): an allow-type and a deny-type button close together,
        // plus the text just above them. Read in tree order; the last such group on screen wins. Bridge Chat relays it to the owner.
        var permission: [String: Any]? = nil
        func isAllow(_ t: String) -> Bool { let l = t.lowercased(); return ["allow", "allow once", "always allow", "allow always", "allow for this chat", "approve", "accept", "run", "yes, allow", "continue"].contains(l) || l.hasPrefix("always allow") || l.hasPrefix("allow for") || l.hasPrefix("allow once") }
        func isDeny(_ t: String) -> Bool { let l = t.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"); return ["deny", "don't allow", "reject", "decline", "no", "cancel", "don't run"].contains(l) || l.hasPrefix("deny") || l.hasPrefix("don't allow") }
        for (i, it) in items.enumerated().reversed() where it.0 == "b" && (isAllow(it.1) || isDeny(it.1)) {
            let lo = max(0, i - 6), hi = min(items.count - 1, i + 6)
            let near = items[lo...hi].filter { $0.0 == "b" && (isAllow($0.1) || isDeny($0.1)) }.map { $0.1 }
            guard near.contains(where: isAllow), near.contains(where: isDeny) else { continue }
            var opts: [String] = []
            for o in near where !opts.contains(o) { opts.append(o) }
            let first = items[lo...hi].firstIndex { $0.0 == "b" && (isAllow($0.1) || isDeny($0.1)) } ?? i
            let text = items[max(0, first - 10)..<first].filter { $0.0 == "t" || $0.0 == "h" }.map { $0.1 }.joined(separator: " ")
            permission = ["prompt": String(text.suffix(600)), "options": opts]
            break
        }
        if !generating { step = "" }
        if step.hasSuffix(" running") { step = String(step.dropLast(8)) }
        if let c = step.range(of: ": "), step.count > 80 { step = String(step[..<c.lowerBound]) }
        return ["window": count > 40, "open": open, "running": running, "generating": generating, "step": String(step.prefix(90)),
                "model": model, "recents": Array(recents.prefix(15)), "turns": keep, "turn_count": turns.count, "permission": permission ?? NSNull()]
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
