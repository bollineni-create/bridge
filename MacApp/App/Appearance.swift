import SwiftUI
import AppKit

/// Bridge's appearance switch (Nov 21, 2026). Auto follows macOS (and its sunset switch); Light and Dark pin this app only.
/// Stored in UserDefaults "appearance" = auto | light | dark, applied at launch and the moment it changes.
enum Appearance {
    static let key = "appearance"
    static func apply(_ v: String) {
        NSApp.appearance = v == "dark" ? NSAppearance(named: .darkAqua) : (v == "light" ? NSAppearance(named: .aqua) : nil)
    }
    static func set(_ v: String) { UserDefaults.standard.set(v, forKey: key); apply(v) }
    static func restore() { apply(UserDefaults.standard.string(forKey: key) ?? "auto") }
}
