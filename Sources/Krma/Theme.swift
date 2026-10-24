import AppKit
import SwiftUI

enum Theme {
    /// Upvote orange, used for the glyph and the chart. Not a Reddit mark, just a color.
    static let accent = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.08, alpha: 1)
    static let positive = NSColor.systemGreen
    static let negative = NSColor.systemRed

    static func change(_ n: Int) -> NSColor {
        n > 0 ? positive : n < 0 ? negative : .secondaryLabelColor
    }

    /// Accent colors as text: the bright system colors are hard to read on a light background,
    /// so in light appearances they're darkened; dark appearances keep them as-is.
    static func readable(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? color
                : (color.blended(withFraction: 0.32, of: .black) ?? color)
        }
    }
}

extension Color {
    init(ns: NSColor) { self.init(nsColor: ns) }
}

/// Card surface: white with a hairline border in light mode, translucent grey in dark mode.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return content
            .background(shape.fill(scheme == .dark ? AnyShapeStyle(.quaternary.opacity(0.5))
                                                   : AnyShapeStyle(Color.white.opacity(0.9))))
            .overlay(shape.strokeBorder(Color.black.opacity(scheme == .dark ? 0 : 0.07), lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
