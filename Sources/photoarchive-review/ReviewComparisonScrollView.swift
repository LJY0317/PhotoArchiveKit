import AppKit
import SwiftUI

/// Own the scroll container; SwiftUI continues to own the comparison Grid.
/// Legacy scrollers reserve space outside the document, including above the
/// window's bottom action bar, and remain usable with a wheel-only mouse.
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

    init(content: Content, documentID: String) {
        hostingView = ComparisonHostingView(rootView: content)
        self.documentID = documentID
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = true
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
            self?.scheduleDocumentResize()
        }
        horizontalScroller?.toolTip = "좌우로 드래그하거나 Shift + 마우스 휠로 비교 열을 이동합니다."
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

    private func resizeDocument(resetPosition: Bool) {
        // Measure only on content/width updates, never on scroll bounds changes.
        // All preview slots have fixed heights, so thumbnail completion needs
        // repainting but does not require a new document measurement.
        let size = hostingView.fittingSize
        if hostingView.frame.size != size {
            hostingView.setFrameSize(size)
        }
        tile()
        let origin = resetPosition ? NSPoint.zero : contentView.bounds.origin
        contentView.scroll(to: contentView.constrainBoundsRect(
            NSRect(origin: origin, size: contentView.bounds.size)
        ).origin)
        reflectScrolledClipView(contentView)
    }
}
