import SwiftUI

/// Glide's design tokens. Tint is Ember until the owner picks another.
public enum Tokens {
    public static let tint = Color(light: 0xCF4310, dark: 0xFF7A3D)
    /// For marks and strokes, where the fill value reads too dark.
    public static let tintGraphic = Color(light: 0xF2551B, dark: 0xFF7A3D)
    public static let iconTop = Color(hex: 0xFF9254)
    public static let iconBottom = Color(hex: 0xEC4A12)
    /// The bar is dark glass in both appearances.
    public static let barGlass = Color(red: 24 / 255, green: 23 / 255, blue: 22 / 255).opacity(0.88)
    /// The one spring every Glide motion uses.
    public static let spring = Animation.spring(response: 0.3, dampingFraction: 0.8)
    public static let popupRadius: CGFloat = 14
    public static let levelAttack: Double = 0.06
    public static let levelRelease: Double = 0.2
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(Color(hex: hex))
        })
    }
}

/// The Caret mark: three voice bars meeting a text caret, on a 64-unit grid.
public struct CaretMark: View {
    /// Colour of the caret; the bars use the foreground style.
    var caret: Color?

    public init(caret: Color? = nil) { self.caret = caret }

    public var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 64
            func pill(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
                Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: w * s / 2)
            }
            var bars = pill(8.5, 24, 8, 16)
            bars.addPath(pill(21.5, 11, 8, 42))
            bars.addPath(pill(34.5, 19, 8, 26))
            ctx.fill(bars, with: .foreground)
            let caretPath = pill(50, 8, 5.5, 48)
            if let caret { ctx.fill(caretPath, with: .color(caret)) } else { ctx.fill(caretPath, with: .foreground) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Glide")
    }
}
