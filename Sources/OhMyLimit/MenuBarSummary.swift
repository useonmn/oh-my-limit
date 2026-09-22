import AppKit
import OhMyLimitCore

@MainActor
enum MenuBarSummary {
    static func image(for entries: [(provider: AccountProvider, text: String)]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let parts = entries.map { entry in
            (logo: ProviderMark.image(for: entry.provider),
             text: NSAttributedString(string: entry.text, attributes: [
                .font: font, .foregroundColor: NSColor.black
             ]))
        }
        let logoSize: CGFloat = 14
        let labelGap: CGFloat = 4
        let accountGap: CGFloat = 10
        let height: CGFloat = 18
        let width = parts.reduce(CGFloat(0)) { $0 + logoSize + labelGap + ceil($1.text.size().width) }
            + CGFloat(max(0, parts.count - 1)) * accountGap
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
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
