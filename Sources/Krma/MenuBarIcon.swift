import AppKit

/// Draws the status-item image: an upvote glyph, the total, the change over the selected period,
/// and up to three favorite subreddits. Monochrome renders as a template image.
@MainActor
enum MenuBarIconRenderer {
    static let height: CGFloat = 18
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    nonisolated private static let glyphWidth: CGFloat = 13

    private enum Run {
        case glyph(NSColor)
        case text(String, NSFont, NSColor)
        case gap(CGFloat)

        var width: CGFloat {
            switch self {
            case .glyph: return glyphWidth
            case .text(let s, let f, _): return ceil((s as NSString).size(withAttributes: [.font: f]).width)
            case .gap(let g): return g
            }
        }
    }

    static func render(store: KarmaStore) -> NSImage {
        let d = UserDefaults.standard
        let mono = d.bool(forKey: SettingsKey.monochrome)
        let exact = d.bool(forKey: SettingsKey.exactNumbers)
        let period = Period.current
        let text: NSColor = mono ? .black : .labelColor
        let dim: NSColor = mono ? .black : .labelColor.withAlphaComponent(0.7)
        func changeColor(_ n: Int) -> NSColor { mono ? .black : Theme.change(n) }

        var runs: [Run] = []
        func group(_ r: [Run]) {
            if !runs.isEmpty { runs.append(.gap(7)) }
            runs += r
        }

        if let c = store.current {
            let delta = store.delta(period)
            var main: [Run] = []
            if d.bool(forKey: SettingsKey.menuBarIcon) { main.append(.glyph(mono ? .black : Theme.accent)); main.append(.gap(3)) }
            if d.bool(forKey: SettingsKey.menuBarTotal) { main.append(.text(KarmaMath.number(c.total, exact: exact), font, text)) }
            if d.bool(forKey: SettingsKey.menuBarChange), let n = delta?.total, n != 0 {
                if !main.isEmpty { main.append(.gap(3)) }
                main.append(.text(arrow(n) + KarmaMath.number(abs(n), exact: exact), smallFont, changeColor(n)))
            }
            if let last = main.last, case .gap = last { main.removeLast() }
            if !main.isEmpty { group(main) }

            let count = max(0, min(3, d.integer(forKey: SettingsKey.menuBarFavorites)))
            let showFavChange = d.bool(forKey: SettingsKey.menuBarFavoriteChange)
            for row in store.favoriteRows.prefix(count) {
                var r: [Run] = [.text(shortName(row.name), labelFont, dim), .gap(2),
                                .text(KarmaMath.number(row.karma.total, exact: exact), smallFont, text)]
                if showFavChange, let n = delta?.subreddits[row.name.lowercased()], n != 0 {
                    r.append(.gap(2))
                    r.append(.text(arrow(n) + KarmaMath.number(abs(n), exact: exact), labelFont, changeColor(n)))
                }
                group(r)
            }
        }

        // Glyph-only mode: nothing enabled, not signed in, or nothing loaded yet.
        guard !runs.isEmpty else {
            let name = store.lastError != nil && !store.hasData ? "exclamationmark.triangle" : "arrowshape.up.fill"
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Krma")!
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!
            img.isTemplate = true
            return img
        }

        let total = runs.reduce(0) { $0 + $1.width }
        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            let mid = height / 2
            for run in runs {
                switch run {
                case .glyph(let color):
                    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                        .applying(.init(paletteColors: [color]))
                    if let symbol = NSImage(systemSymbolName: "arrowshape.up.fill", accessibilityDescription: nil)?
                        .withSymbolConfiguration(config) {
                        let s = symbol.size
                        symbol.draw(in: NSRect(x: x + (glyphWidth - s.width) / 2, y: mid - s.height / 2, width: s.width, height: s.height))
                    }
                case .text(let s, let f, let color):
                    let size = (s as NSString).size(withAttributes: [.font: f])
                    (s as NSString).draw(at: NSPoint(x: x, y: mid - size.height / 2), withAttributes: [.font: f, .foregroundColor: color])
                case .gap: break
                }
                x += run.width
            }
            return true
        }
        image.isTemplate = mono
        return image
    }

    private static func arrow(_ n: Int) -> String { n > 0 ? "▲" : "▼" }

    /// Subreddit names longer than 10 characters are trimmed so three favorites still fit.
    static func shortName(_ name: String) -> String {
        name.count > 10 ? String(name.prefix(9)) + "…" : name
    }
}
