import AppKit
import OhMyLimitCore

@MainActor
enum MenuBarSummary {
    private static let logoSize: CGFloat = 14
    private static let labelGap: CGFloat = 4
    private static let accountGap: CGFloat = 10
    private static let height: CGFloat = 18

    private static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    }

    private static func attributedText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.black
        ])
    }

    /// Natural, uncapped width of the entries; `MenuBarPresentation.fit` compares it to the cap.
    static func width(for entries: [MenuBarEntry]) -> CGFloat {
        entries.reduce(CGFloat(0)) {
            $0 + logoSize + labelGap + ceil(attributedText($1.text).size().width)
        } + CGFloat(max(0, entries.count - 1)) * accountGap
    }

    static func image(for entries: [MenuBarEntry]) -> NSImage {
        let parts = entries.map { entry in
            (logo: ProviderMark.image(for: entry.provider), text: attributedText(entry.text))
        }
        let height = Self.height
        let logoSize = Self.logoSize
        let labelGap = Self.labelGap
        let accountGap = Self.accountGap
        let imageWidth = min(Theme.menuBarMaximumWidth, width(for: entries))
        let image = NSImage(size: NSSize(width: imageWidth, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.logo.draw(in: NSRect(x: x, y: (height - logoSize) / 2,
                                         width: logoSize, height: logoSize))
                x += logoSize + labelGap
                let size = part.text.size()
                part.text.draw(at: NSPoint(x: x, y: floor((height - size.height) / 2)))
                x += ceil(size.width) + accountGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
