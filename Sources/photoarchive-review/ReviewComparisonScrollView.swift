import AppKit
import SwiftUI

/// Own the scroll container; SwiftUI continues to own the comparison Grid.
/// The legacy vertical scroller remains outside the document and usable with a
/// wheel-only mouse. The horizontal scroller is installed only for real overflow
/// so an unused scroller slot does not leave a strip above the bottom action bar.
struct ReviewComparisonScrollView<Content: View>: NSViewRepresentable {
    let documentID: String
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> ComparisonScrollContainer<Content> {
        ComparisonScrollContainer(content: content(), documentID: documentID)
    }

    func updateNSView(_ view: ComparisonScrollContainer<Content>, context: Context) {
        view.update(content: content(), documentID: documentID)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComparisonScrollContainer<Content>,
                      context: Context) -> CGSize? {
        // The viewport accepts the parent's size, never the wide/tall document's.
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

private final class ComparisonHostingView<Content: View>: NSHostingView<Content> {
    var intrinsicContentSizeDidInvalidate: (() -> Void)?
    var layoutDidComplete: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        intrinsicContentSizeDidInvalidate?()
    }

    override func layout() {
        super.layout()
        layoutDidComplete?()
    }
}

final class ComparisonScrollContainer<Content: View>: NSScrollView {
    private let hostingView: ComparisonHostingView<Content>
    private var documentID: String
    private var hasScheduledDocumentResize = false
    private var isResizingDocument = false
    private var isUpdatingHorizontalScroller = false

    init(content: Content, documentID: String) {
        hostingView = ComparisonHostingView(rootView: content)
        self.documentID = documentID
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = true
        scrollerStyle = .legacy
        autohidesScrollers = false
        automaticallyAdjustsContentInsets = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .automatic
        hostingView.sizingOptions = [.intrinsicContentSize]
        documentView = hostingView
        hostingView.intrinsicContentSizeDidInvalidate = { [weak self] in
            self?.scheduleDocumentResize()
        }
        hostingView.layoutDidComplete = { [weak self] in
            self?.resizeDocumentAfterHostedLayout()
        }
        resizeDocument(resetPosition: true)
    }

    required init?(coder: NSCoder) { nil }

    func update(content: Content, documentID: String) {
        let changedGroup = self.documentID != documentID
        self.documentID = documentID
        hostingView.rootView = content
        hostingView.layoutSubtreeIfNeeded()
        resizeDocument(resetPosition: changedGroup)
    }

    override func layout() {
        super.layout()
        updateHorizontalScrollerAvailability()
        updateTopFade()
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        updateTopFade()
    }

    private func scheduleDocumentResize() {
        guard !hasScheduledDocumentResize else { return }
        hasScheduledDocumentResize = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hostingView.layoutSubtreeIfNeeded()
            self.resizeDocument(resetPosition: false)
            self.hasScheduledDocumentResize = false
        }
    }

    private func resizeDocumentAfterHostedLayout() {
        guard !isResizingDocument else { return }
        let size = hostingView.fittingSize
        guard hostingView.frame.size != size else { return }
        isResizingDocument = true
        resizeDocument(resetPosition: false, measuredSize: size)
        isResizingDocument = false
    }

    private func resizeDocument(resetPosition: Bool, measuredSize: NSSize? = nil) {
        // Measure only on content/width updates, never on scroll bounds changes.
        // All preview slots have fixed heights, so thumbnail completion needs
        // repainting but does not require a new document measurement.
        let size = measuredSize ?? hostingView.fittingSize
        let origin = resetPosition ? NSPoint.zero : contentView.bounds.origin

        // Document-height changes (for example showing advanced metadata)
        // should not retile the whole scroll view or animate the hosted frame.
        // Retiling is handled by the scroll view's normal layout when the
        // viewport itself changes; here we only update the document extent and
        // preserve the visible origin.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            if hostingView.frame.size != size {
                hostingView.setFrameSize(size)
            }
            contentView.scroll(to: contentView.constrainBoundsRect(
                NSRect(origin: origin, size: contentView.bounds.size)
            ).origin)
        }
        updateHorizontalScrollerAvailability(documentWidth: size.width)
        reflectScrolledClipView(contentView)
        updateTopFade()
    }

    private func updateHorizontalScrollerAvailability(documentWidth: CGFloat? = nil) {
        guard !isUpdatingHorizontalScroller, bounds.width > 0 else { return }
        let width = documentWidth ?? documentView?.frame.width ?? 0
        let needsHorizontalScroller = width > contentView.bounds.width + 0.5
        guard hasHorizontalScroller != needsHorizontalScroller else { return }

        isUpdatingHorizontalScroller = true
        let origin = contentView.bounds.origin
        hasHorizontalScroller = needsHorizontalScroller
        if needsHorizontalScroller {
            horizontalScroller?.toolTip = "좌우로 드래그하거나 Shift + 마우스 휠로 비교 열을 이동합니다."
        }
        tile()
        contentView.scroll(to: contentView.constrainBoundsRect(
            NSRect(origin: origin, size: contentView.bounds.size)
        ).origin)
        reflectScrolledClipView(contentView)
        updateTopFade()
        isUpdatingHorizontalScroller = false
    }

    private func updateTopFade() {
        ReviewScrollEdgeFade.update(
            in: self,
            occlusionHeight: ReviewScrollEdgeFade.defaultLength,
            fadeLength: ReviewScrollEdgeFade.defaultLength
        )
    }
}
