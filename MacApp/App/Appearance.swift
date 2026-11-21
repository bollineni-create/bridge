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

/// Three-way switch pinned to the foot of the sidebar (the night room, so it is drawn light-on-black in every mode).
struct AppearanceSwitch: View {
    @AppStorage(Appearance.key) private var mode = "auto"
    private let options: [(String, String, String)] = [("auto", "circle.lefthalf.filled", "Auto"), ("light", "sun.max", "Light"), ("dark", "moon", "Dark")]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { o in
                let on = mode == o.0
                Button { withAnimation(.easeOut(duration: 0.2)) { mode = o.0 }; Appearance.apply(o.0) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: o.1).font(.system(size: 11, weight: .semibold))
                        Text(o.2).font(SW.a(12.5, on ? 700 : 500))
                    }
                    .foregroundStyle(on ? Color.white : SW.nightQuiet)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(on ? Color.white.opacity(0.14) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(o.0 == "auto" ? "Follow macOS appearance" : "Always \(o.2.lowercased())")
            }
        }
        .padding(2)
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 16)
        .accessibilityLabel("Appearance")
    }
}
