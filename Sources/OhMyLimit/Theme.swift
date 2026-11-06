import AppKit
import SwiftUI

enum Theme {
    /// Usage popover width. Settings open in the same panel at `settingsWidth`.
    static let width: CGFloat = 272
    static let settingsWidth: CGFloat = 320
    static let menuBarAccountLimit = 3
    static let menuBarMaximumWidth: CGFloat = 240
    static let panelMinimumHeight: CGFloat = 136
    static let panelMaximumHeight: CGFloat = 527
    static let selectorHeight: CGFloat = 142
    static let scrollingSelectorHeight: CGFloat = 153
    static let ringProviderSize: CGFloat = 19
    static let detailProviderSize: CGFloat = 14
    static let panelControlSize: CGFloat = 22
    static let panelDismissSize: CGFloat = 17
    static let panelMenuSize: CGFloat = 20
    static let settingsControlSize: CGFloat = 26
    static let settingsHeaderHeight: CGFloat = 40
    static func settingsHeight(accountCount: Int) -> CGFloat {
        min(420, 330 + CGFloat(accountCount) * 35)
    }
    // Concentric geometry (WWDC25 "Get to know the new design system"):
    // inner radius = outer radius - inset, and group content is padded by its
    // own radius, so every text edge sits on the panel radius (10 + 12 = 22).
    static let panelInset: CGFloat = 10
    static let panelRadius: CGFloat = 22
    static let panelHeader: CGFloat = 34
    static let panelTitle = Font.system(size: 11, weight: .semibold)
    static let panelAccount = Font.system(size: 12, weight: .semibold)
    static let panelBody = Font.system(size: 11)
    static let panelCaption = Font.system(size: 10.5)
    static let panelValue = Font.system(size: 11, weight: .semibold).monospacedDigit()
    static let ringValue = Font.system(size: 17, weight: .semibold).monospacedDigit()
    static let ringLabel = Font.system(size: 10.5, weight: .medium)
    static let ringSize: CGFloat = 48
    static let ringStroke: CGFloat = 5
    static let accountButtonWidth: CGFloat = 75
    static let panelSmall: CGFloat = 4
    static let panelCompact: CGFloat = 7
    static let panelGap: CGFloat = 10
    static let panelGroupRadius: CGFloat = panelRadius - panelInset
    static let panelPadding: CGFloat = panelGroupRadius
    static let panelTextInset: CGFloat = panelInset + panelPadding
    /// Edge padding that puts an icon glyph, not its larger hit area, on the text line.
    static func opticalInset(control: CGFloat, glyph: CGFloat) -> CGFloat {
        panelTextInset - (control - glyph) / 2
    }
    static let settingsTitle = Font.system(size: 12, weight: .semibold)
    static let settingsBody = Font.system(size: 12)
    static let panelSelected = Color.primary.opacity(0.10)
    static let panelTrack = Color.primary.opacity(0.15)
    static let panelPrimary = Color(nsColor: .labelColor)
    static let panelSecondary = Color(nsColor: .secondaryLabelColor)
    static let mint = adaptive(light: 0x0B9E6B, dark: 0x30E8A0)
    /// Account login and login cancellation (DESIGN §5).
    static let link = Color(nsColor: .linkColor)
    static let panelWarning = adaptive(light: 0x9A4E00, dark: 0xFFB45E)
    static let panelCritical = adaptive(light: 0xD92D20, dark: 0xFF654F)
    static let panelSeparator = Color(nsColor: .separatorColor)
    static let small: CGFloat = 4
    static let compact: CGFloat = 8
    static let gap: CGFloat = 12
    static let barHeight: CGFloat = 4
    static let account = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let panelGroup = Color.primary.opacity(0.055)

    static func usageColor(_ percent: Double) -> Color {
        percent >= 95 ? panelCritical : percent >= 80 ? panelWarning : mint
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

/// Legacy menu material for macOS versions before Liquid Glass.
private struct MenuMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// One native surface over the transparent hosting panel. Legacy menu
    /// material does not reproduce the Liquid Glass used by modern menus.
    @ViewBuilder
    func menuSurface() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        } else {
            background(MenuMaterialView())
                .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        }
    }

    /// Quiet inset group on the menu surface: a faint fill and a hairline,
    /// like the grouped rows in Control Center panels.
    func menuGroup(radius: CGFloat = Theme.panelGroupRadius) -> some View {
        modifier(MenuGroup(radius: radius))
    }

    /// Flat selection fill behind the selected account ring.
    func menuSelection(_ selected: Bool) -> some View {
        modifier(MenuSelection(selected: selected))
    }
}

private struct MenuGroup: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.panelGroup)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.panelSeparator.opacity(0.6), lineWidth: 0.5)
            }
    }
}

private struct MenuSelection: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.panelGroupRadius, style: .continuous)
                    .fill(selected ? Theme.panelSelected : .clear)
            }
    }
}
