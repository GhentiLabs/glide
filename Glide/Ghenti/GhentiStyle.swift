import AppKit
import CoreText
import SwiftUI

/// Ghenti's own look, as on auth.ghenti.com: warm paper and ink, Geist for text, the Migra wordmark, pill buttons.
/// Glide's orange stays out of anything Ghenti draws.
enum Ghenti {
    static let ink = Color(light: 0x0A0A0A, dark: 0xF5F1E8)
    static let surface = Color(light: 0xF5F1E8, dark: 0x0A0A0A)
    static let elevated = Color(light: 0xFAF6ED, dark: 0x15120E)
    static let sunken = Color(light: 0xEDE7D8, dark: 0x050505)
    static let rule = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(white: 0.96, alpha: 0.16) : NSColor(white: 0.04, alpha: 0.16) })
    static let muted = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(white: 0.96, alpha: 0.62) : NSColor(white: 0.04, alpha: 0.62) })
    static let error = Color(light: 0xB3261E, dark: 0xFF8A80)
    static let ok = Color(light: 0x1D6B3A, dark: 0x81C995)

    /// Geist ships with the app under the SIL Open Font License (Fonts/Geist-OFL.txt).
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        registerFonts
        return .custom("Geist", size: size).weight(weight)
    }

    private static let registerFonts: Void = {
        if let url = Bundle.main.url(forResource: "Geist", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

/// "Ghenti" in Migra, drawn as outlines (Assets: GhentiWordmark), so the app carries the logo, not the font.
struct GhentiWordmark: View {
    var height: CGFloat = 26

    var body: some View {
        Image("GhentiWordmark").renderingMode(.template).resizable().scaledToFit()
            .frame(height: height).foregroundStyle(Ghenti.ink)
            .accessibilityLabel("Ghenti")
    }
}

/// The 25 rem card the Ghenti sign-in pages sit in.
struct GhentiCard<Content: View>: View {
    var width: CGFloat = 400
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 28)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Ghenti.elevated))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Ghenti.rule))
    }
}

/// Ink pill for the main action; outlined pill for the other.
struct GhentiButtonStyle: ButtonStyle {
    var secondary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ghenti.font(15, .semibold))
            .foregroundStyle(secondary ? Ghenti.ink : Ghenti.surface)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(Capsule().fill(secondary ? Color.clear : Ghenti.ink))
            .overlay(Capsule().strokeBorder(secondary ? Ghenti.rule : .clear))
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
