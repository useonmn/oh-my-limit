import AppKit
import SwiftUI

enum Theme {
    static let width: CGFloat = 320
    static func settingsHeight(accountCount: Int) -> CGFloat {
        min(420, 280 + CGFloat(accountCount) * 35)
    }
    static let panelInset: CGFloat = 16
    static let panelRadius: CGFloat = 20
    static let panelTitle = Font.system(size: 12, weight: .semibold)
    static let panelAccount = Font.system(size: 13, weight: .semibold)
    static let panelBody = Font.system(size: 12)
    static let ringValue = Font.system(size: 20, weight: .semibold).monospacedDigit()
    static let ringLabel = Font.system(size: 11, weight: .medium)
    static let ringSize: CGFloat = 56
    static let ringStroke: CGFloat = 6
    static let accountButtonWidth: CGFloat = 88
    static let panelSurface = Color(nsColor: .windowBackgroundColor)
    static let panelDetail = Color(nsColor: .controlBackgroundColor)
    static let panelSelected = Color.primary.opacity(0.10)
    static let panelTrack = Color.primary.opacity(0.15)
    static let panelPrimary = Color(nsColor: .labelColor)
    static let panelSecondary = Color(nsColor: .secondaryLabelColor)
    static let mint = adaptive(light: 0x0B9E6B, dark: 0x30E8A0)
    static let panelWarning = adaptive(light: 0x9A4E00, dark: 0xFFB45E)
    static let panelCritical = adaptive(light: 0xD92D20, dark: 0xFF654F)
    static let panelSeparator = Color(nsColor: .separatorColor)
    static let small: CGFloat = 4
    static let compact: CGFloat = 8
    static let gap: CGFloat = 12
    static let padding: CGFloat = 16
    static let section: CGFloat = 20
    static let large: CGFloat = 24
    static let radius: CGFloat = 12
    static let barHeight: CGFloat = 5
    static let title = Font.system(size: 18, weight: .semibold)
    static let account = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let value = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let panelGroup = Color.primary.opacity(0.055)
    static let warningText = Color(nsColor: NSColor(name: "UsageWarning") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(calibratedRed: 1, green: 0.65, blue: 0.20, alpha: 1)
        } else {
            NSColor(calibratedRed: 0.60, green: 0.30, blue: 0, alpha: 1)
        }
    })

    static func usageColor(_ percent: Double) -> Color {
        percent >= 95 ? panelCritical : percent >= 80 ? panelWarning : mint
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: Double((hex >> 16) & 255) / 255,
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
    func menuGroup() -> some View {
        modifier(MenuGroup())
    }

    /// Flat selection fill behind the selected account ring.
    func menuSelection(_ selected: Bool) -> some View {
        modifier(MenuSelection(selected: selected))
    }
}

private struct MenuGroup: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.panelGroup)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.panelSeparator.opacity(0.6), lineWidth: 0.5)
            }
    }
}

private struct MenuSelection: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(selected ? Theme.panelSelected : .clear)
            }
    }
}
