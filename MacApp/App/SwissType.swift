import SwiftUI
import CoreText

/// bollineni.co type and the colours the Swiss restyle adds (Nov 20, 2026). Archivo is registered at launch by
/// CompactScene (BridgeKit carries the font), so Bridge's own windows can use it too. Falls back to SF if it is missing.
enum SW {
    static let red = Color(red: 0.839, green: 0.180, blue: 0.122)          // #D62E1F, the one accent
    static let nightQuiet = Color(red: 0.659, green: 0.659, blue: 0.659)   // #A8A8A8
    static func a(_ size: CGFloat, _ weight: CGFloat = 400, width: CGFloat = 100) -> Font {
        let attrs: [CFString: Any] = [kCTFontNameAttribute: "Archivo", kCTFontVariationAttribute: [0x77676874: weight, 0x77647468: width]]
        let ct = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
        if (CTFontCopyFamilyName(ct) as String).hasPrefix("Archivo") { return Font(ct) }
        return .system(size: size, weight: weight >= 800 ? .heavy : weight >= 600 ? .semibold : .regular)
    }
    static func display(_ size: CGFloat) -> Font { a(size, 900, width: 125) }
    static func heading(_ size: CGFloat) -> Font { a(size, 800, width: 112) }
}
