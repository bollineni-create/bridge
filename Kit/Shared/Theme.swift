import SwiftUI
import CoreText

/// "Swiss Tombstone", the bollineni.co design system: white paper, black ink, one red accent,
/// Archivo wide and heavy for names and figures, square corners, 2px black rules.
/// The only other colour belongs to the runners, and only while they work (the site's launcher rule:
/// only the chosen app is in colour).
enum D {
    static let paper = Color.white
    static let ink = Color.black
    static let body = Color(hex: 0x262626)
    static let quiet = Color(hex: 0x5E5E5E)
    static let hair = Color(hex: 0xCFCFCF)
    static let wash = Color(hex: 0xF2F2F2)
    static let red = Color(hex: 0xD62E1F)
    // the night room (Bridge's sidebar, the unfolded rail)
    static let night = Color.black
    static let nightLine = Color(hex: 0x303030)
    static let nightQuiet = Color(hex: 0xA8A8A8)
    static let nightBody = Color(hex: 0xDADADA)
    // runner tints
    static let ultra = Color(hex: 0xFF9F0A)
    static let pro = Color(hex: 0xBF5AF2)
    static let mac = Color(hex: 0x40C8E0)

    static func color(_ who: String?) -> Color {
        switch who ?? "" { case "ultra": return ultra; case "pro": return pro; case "local": return mac; case "naren": return red; default: return quiet }
    }
    static func code(_ who: String?) -> String {
        switch who ?? "" { case "ultra": return "ULT"; case "pro": return "PRO"; case "local": return "MAC"; case "naren": return "YOU"; case "any": return "ANY"; case "parked": return "PRK"; default: return "—" }
    }
    static func name(_ who: String?) -> String {
        switch who ?? "" { case "ultra": return "Ultra"; case "pro": return "Pro"; case "local": return "Mac"; default: return (who ?? "").capitalized }
    }

    // MARK: Archivo, bundled as a variable font (wght 100–900, wdth 62–125)
    static func registerFonts() {
        guard let url = Bundle(for: Store.self).url(forResource: "Archivo", withExtension: "ttf") ?? Bundle.main.url(forResource: "Archivo", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    /// width: 100 normal, 112 the site's "wide", 125 the hero.
    static func a(_ size: CGFloat, _ weight: CGFloat = 400, width: CGFloat = 100) -> Font {
        let attrs: [CFString: Any] = [
            kCTFontNameAttribute: "Archivo",
            kCTFontVariationAttribute: [0x77676874: weight, 0x77647468: width],   // 'wght', 'wdth'
        ]
        let ct = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
        if (CTFontCopyFamilyName(ct) as String).hasPrefix("Archivo") { return Font(ct) }
        return .system(size: size, weight: weight >= 800 ? .heavy : weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
    }
    static func display(_ size: CGFloat) -> Font { a(size, 900, width: 125) }
    static func heading(_ size: CGFloat) -> Font { a(size, 800, width: 112) }
    static let mono = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let monoSmall = Font.system(size: 12, weight: .regular, design: .monospaced)
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

/// Wordmark with the site's red period: "Bridge."
struct Wordmark: View {
    var text: String = "Bridge"
    var size: CGFloat = 34
    var onDark = false
    var body: some View {
        (Text(text).foregroundColor(onDark ? .white : D.ink) + Text(".").foregroundColor(D.red))
            .font(D.display(size)).tracking(-size * 0.05).lineLimit(1).fixedSize()
    }
}

/// Square runner chip: filled with the tint while the runner is active, grey outline when not.
struct Badge: View {
    var who: String?
    var filled = true
    var big = false
    var body: some View {
        Text(D.code(who))
            .font(.system(size: big ? 12 : 10.5, weight: .bold, design: .monospaced))
            .foregroundStyle(filled ? Color.black : D.quiet)
            .frame(width: big ? 40 : 34, height: big ? 40 : 18)
            .background(filled ? D.color(who) : Color.clear)
            .overlay(Rectangle().strokeBorder(filled ? Color.clear : D.quiet.opacity(0.7), lineWidth: 1))
    }
}

struct Eyebrow: View {
    var text: String
    var color: Color = D.quiet
    var body: some View { Text(text.uppercased()).font(D.a(11.5, 700, width: 112)).tracking(0.9).foregroundStyle(color) }
}

/// The site's .btn: square with a 2px black border; solid = black fill; pressed goes red like the site's hover.
struct SquareButton: ButtonStyle {
    var solid = false
    var quiet = false     // text-only secondary, as in the designs ("Open", "Deny")
    func makeBody(configuration: Configuration) -> some View {
        let hot = configuration.isPressed
        configuration.label.font(D.a(13.5, 700))
            .foregroundStyle(hot || solid ? Color.white : D.ink)
            .padding(.horizontal, quiet ? 8 : 12).frame(minHeight: 30)
            .background(hot ? D.red : (solid ? D.ink : Color.clear))
            .overlay(Rectangle().strokeBorder(hot ? D.red : (quiet ? Color.clear : D.ink), lineWidth: 2))
            .contentShape(Rectangle())
    }
}

/// Tombstones: equal boxes joined by 2px black lines inside a 2px black frame; one inverted.
struct Tombstones: View {
    struct Stone: Identifiable { var id: String { label }; var figure: String; var label: String; var inverted = false; var red = false; var tap: (() -> Void)? = nil }
    var stones: [Stone]
    var size: CGFloat = 30
    var body: some View {
        HStack(spacing: 2) {
            ForEach(stones) { s in
                Button { s.tap?() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.figure).font(D.heading(size)).tracking(-size * 0.045).monospacedDigit()
                            .foregroundStyle(s.inverted ? Color.white : (s.red ? D.red : D.ink))
                        Text(s.label).font(D.a(12.5, 500)).foregroundStyle(s.inverted ? Color.white : (s.red ? D.red : D.ink))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(s.inverted ? D.ink : D.paper)
                }
                .buttonStyle(.plain).allowsHitTesting(s.tap != nil)
            }
        }
        .padding(2)
        .background(D.ink)
    }
}

/// Underline tabs (the site's nav): selected = black label with a red bar under it, on a 2px black rule.
struct UnderlineTabs: View {
    var items: [String]
    @Binding var selected: String
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { i in
                let on = selected == i
                Button { selected = i } label: {
                    Text(i).font(D.a(14, on ? 700 : 500)).foregroundStyle(on ? D.ink : D.quiet)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? D.red : Color.clear).frame(height: 3) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(D.ink).frame(height: 2).offset(y: 2) }
    }
}

struct Rule: View {
    var heavy = false
    var color: Color = D.ink
    var body: some View { Rectangle().fill(color).frame(height: heavy ? 2 : 1) }
}

/// Page heading: heavy wide title, quiet line under it, optional red count box.
struct PageTitle: View {
    var title: String
    var sub: String = ""
    var count: Int = 0
    var size: CGFloat = 34
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(D.display(size)).tracking(-size * 0.05).foregroundStyle(D.ink).lineLimit(1).minimumScaleFactor(0.7)
                if !sub.isEmpty { Text(sub).font(D.a(14)).foregroundStyle(D.quiet) }
            }
            Spacer()
            if count > 0 { RedCount(n: count) }
        }
    }
}

struct RedCount: View {
    var n: Int
    var words = false
    var body: some View {
        Text(words ? "\(n) need you" : "\(n)").font(D.a(13, 700)).foregroundStyle(.white)
            .padding(.horizontal, words ? 12 : 8).frame(minWidth: 24, minHeight: 24).background(D.red)
    }
}

/// "Still" rendering (screenshots via ImageRenderer, which draws neither scroll views nor text fields).
struct StillKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var still: Bool { get { self[StillKey.self] } set { self[StillKey.self] = newValue } } }

/// A ScrollView that lays its content out flat when rendering stills.
struct Scroller<Content: View>: View {
    @Environment(\.still) private var still
    @ViewBuilder var content: Content
    var body: some View {
        if still { VStack(spacing: 0) { content; Spacer(minLength: 0) } } else { ScrollView { content } }
    }
}
