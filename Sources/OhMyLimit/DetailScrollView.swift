import AppKit
import SwiftUI

/// Native overlay scrolling keeps the document width independent of scrollbar visibility.
struct DetailScrollView<Content: View>: NSViewRepresentable {
    let width: CGFloat
    let content: Content

    init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    private var hostedContent: AnyView {
        AnyView(content
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Theme.panelPrimary)
            .tint(Theme.mint))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = OverlayDetailScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.scrollerInsets = NSEdgeInsets(
            top: Theme.padding, left: 0, bottom: Theme.padding, right: Theme.small
        )
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Theme.radius
        scroll.layer?.masksToBounds = true
        scroll.documentView = NSHostingView(rootView: hostedContent)
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // This representable creates and owns the document view.
        let host = scroll.documentView as! NSHostingView<AnyView>
        host.rootView = hostedContent
        host.setFrameSize(host.fittingSize)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let height = nsView.documentView!.frame.height
        return CGSize(width: width, height: min(proposal.height ?? height, height))
    }
}

private final class OverlayDetailScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set {
            // AppKit can reapply the global legacy style when preferences change.
            // Pin only this viewport; never mutate the user's global preference.
            if super.scrollerStyle != .overlay { super.scrollerStyle = .overlay }
        }
    }
}
