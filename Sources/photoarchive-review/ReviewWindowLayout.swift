import AppKit
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let photoArchiveToggleSidebar = Notification.Name("PhotoArchiveToggleSidebar")
}

enum ReviewVisualStyle {
    static let detailSurface = Color(nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        if match == .darkAqua {
            return NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1)
        }
        return .white
    })

    static let comparisonSurface = detailSurface
    static let selectionAccent = Color(nsColor: .selectedContentBackgroundColor)
    static let sidebarSelection = Color.primary.opacity(0.08)
    static let sidebarHover = Color.primary.opacity(0.05)
    static let sidebarPressed = Color.primary.opacity(0.12)
    static let sidebarKeyboardFocus = Color(nsColor: .separatorColor).opacity(0.9)
    static let sidebarMaterial: NSVisualEffectView.Material = .windowBackground
}

enum ReviewSidebarLayoutMetrics {
    static let minimumWidth: CGFloat = 240
    static let preferredWidth: CGFloat = 290
    static let maximumWidth: CGFloat = 520
    static let rowHorizontalInset: CGFloat = 8
    static let rowCornerRadius: CGFloat = 10
    static let rowMinimumHeight: CGFloat = 44
    @MainActor
    static var rowTrailingInset: CGFloat {
        max(
            rowHorizontalInset,
            NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) + 3
        )
    }
}

struct ReviewSidebarScrollView<Content: View>: NSViewRepresentable {
    let scrollTargetID: String?
    @ViewBuilder let content: () -> Content

    init(scrollTargetID: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.scrollTargetID = scrollTargetID
        self.content = content
    }

    func makeNSView(context: Context) -> ReviewSidebarScrollMaterialView<Content> {
        ReviewSidebarScrollMaterialView(content: content(), scrollTargetID: scrollTargetID)
    }

    func updateNSView(_ nsView: ReviewSidebarScrollMaterialView<Content>, context: Context) {
        nsView.update(content: content(), scrollTargetID: scrollTargetID)
    }
}

private struct ReviewSidebarHostedScroll<Content: View>: View {
    let content: Content
    let scrollTargetID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        ReviewSidebarScrollConfigurator()
                            .allowsHitTesting(false)
                    )
            }
            .onAppear {
                guard let scrollTargetID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(scrollTargetID)
                }
            }
            .onChange(of: scrollTargetID) { _, targetID in
                guard let targetID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(targetID)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keep the sidebar's actual NSScrollView inside a semantic sidebar material.
/// An NSScroller draws its expanded drag track using the visual environment of
/// its ancestors. A material used only as a SwiftUI background is a sibling,
/// so the native overlay track can otherwise fall back to the white window
/// surface while it is being dragged.
final class ReviewSidebarScrollMaterialView<Content: View>: NSVisualEffectView {
    private let hostingView: NSHostingView<ReviewSidebarHostedScroll<Content>>

    init(content: Content, scrollTargetID: String?) {
        hostingView = NSHostingView(
            rootView: ReviewSidebarHostedScroll(content: content, scrollTargetID: scrollTargetID)
        )
        super.init(frame: .zero)

        identifier = NSUserInterfaceItemIdentifier("PhotoArchiveSidebarScrollMaterial")
        material = ReviewVisualStyle.sidebarMaterial
        blendingMode = .behindWindow
        state = .followsWindowActiveState

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(content: Content, scrollTargetID: String?) {
        material = ReviewVisualStyle.sidebarMaterial
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        hostingView.rootView = ReviewSidebarHostedScroll(
            content: content,
            scrollTargetID: scrollTargetID
        )
    }
}

private struct ReviewSidebarScrollConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ReviewSidebarScrollConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ReviewSidebarScrollConfigurationView else { return }
        view.configureEnclosingScrollView()
    }
}

private final class ReviewSidebarScrollConfigurationView: NSView {
    private weak var observedClipView: NSClipView?

    deinit {
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleConfiguration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    override func layout() {
        super.layout()
        configureEnclosingScrollView()
    }

    func configureEnclosingScrollView() {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                // Preserve the user's visibility preference while avoiding a
                // dedicated layout gutter. If the system preference is
                // legacy/always-visible, keep the native overlay scroller
                // visible instead of reserving 17pt beside the content.
                scrollView.autohidesScrollers = NSScroller.preferredScrollerStyle == .overlay
                scrollView.drawsBackground = false
                scrollView.contentView.drawsBackground = false
                scrollView.scrollerKnobStyle = .default
                observeBoundsChanges(in: scrollView)
                ReviewScrollEdgeFade.update(
                    in: scrollView,
                    occlusionHeight: ReviewScrollEdgeFade.defaultLength
                )
                return
            }
            ancestor = view.superview
        }
    }

    private func scheduleConfiguration() {
        configureEnclosingScrollView()
        DispatchQueue.main.async { [weak self] in
            self?.configureEnclosingScrollView()
        }
    }

    private func observeBoundsChanges(in scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        guard observedClipView !== clipView else { return }

        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }

        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              let scrollView = clipView.enclosingScrollView else { return }
        ReviewScrollEdgeFade.update(
            in: scrollView,
            occlusionHeight: ReviewScrollEdgeFade.defaultLength
        )
    }
}

/// Applies the ChatGPT-style scroll-edge fade to the clip view only. The
/// native NSScroller remains a sibling of the clip view, so it stays crisp and
/// visible while only scrolling content fades near the fixed header edge.
enum ReviewScrollEdgeFade {
    static let defaultLength: CGFloat = 20
    private static let maskName = "PhotoArchiveTopScrollFadeMask"

    @MainActor
    static func update(
        in scrollView: NSScrollView,
        occlusionHeight: CGFloat,
        fadeLength: CGFloat = defaultLength
    ) {
        let clipView = scrollView.contentView
        let shouldFade = isScrolledPastTop(scrollView)
        let clampedOcclusion = max(0, occlusionHeight)
        let clampedFade = max(0, min(fadeLength, clampedOcclusion))

        guard shouldFade,
              clampedOcclusion > 0,
              clampedFade > 0,
              clipView.bounds.height > 0 else {
            removeManagedMask(from: clipView)
            return
        }

        clipView.wantsLayer = true
        guard let clipLayer = clipView.layer else { return }

        let gradient: CAGradientLayer
        if let existing = clipLayer.mask as? CAGradientLayer,
           existing.name == maskName {
            gradient = existing
        } else {
            gradient = CAGradientLayer()
            gradient.name = maskName
            clipLayer.mask = gradient
        }

        let height = clipView.bounds.height
        let occlusion = min(clampedOcclusion, height)
        let fade = min(clampedFade, occlusion)
        let fadeStart = max(0, occlusion - fade)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = clipView.bounds
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
        ]
        gradient.locations = [
            0,
            NSNumber(value: Double(fadeStart / height)),
            NSNumber(value: Double(occlusion / height)),
            1,
        ]
        // NSClipView is normally flipped. Keep the first stop at the visual
        // top regardless of the hosting view's coordinate orientation.
        if clipView.isFlipped {
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        } else {
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
        }
        CATransaction.commit()
    }

    @MainActor
    static func isScrolledPastTop(_ scrollView: NSScrollView) -> Bool {
        if let documentView = scrollView.documentView, documentView.isFlipped {
            return scrollView.contentView.bounds.minY > documentView.frame.minY + 0.5
        }
        if let verticalScroller = scrollView.verticalScroller {
            return verticalScroller.floatValue > 0.001
        }
        return scrollView.contentView.bounds.minY > 0.5
    }

    @MainActor
    private static func removeManagedMask(from clipView: NSClipView) {
        guard let mask = clipView.layer?.mask, mask.name == maskName else { return }
        clipView.layer?.mask = nil
    }
}

struct ReviewWindowLayout<Sidebar: View, Detail: View, Actions: View>: View {
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var actions: () -> Actions
    @State private var sidebarWidth = ReviewSidebarLayoutMetrics.preferredWidth
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var isSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                sidebar()
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(ReviewSidebarMaterial().ignoresSafeArea())

                ReviewSidebarDivider(
                    onDragChanged: resizeSidebar,
                    onDragEnded: finishSidebarResize
                )
            }

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReviewVisualStyle.detailSurface.ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReviewWindowChromeConfigurator().allowsHitTesting(false))
        .onReceive(NotificationCenter.default.publisher(for: .photoArchiveToggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.16)) {
                isSidebarVisible.toggle()
            }
        }
    }

    private func resizeSidebar(_ translation: CGFloat) {
        let start = sidebarDragStartWidth ?? sidebarWidth
        if sidebarDragStartWidth == nil {
            sidebarDragStartWidth = sidebarWidth
        }
        sidebarWidth = min(
            ReviewSidebarLayoutMetrics.maximumWidth,
            max(ReviewSidebarLayoutMetrics.minimumWidth, start + translation)
        )
    }

    private func finishSidebarResize() {
        sidebarDragStartWidth = nil
    }

    @ViewBuilder
    private var detailColumn: some View {
        if #available(macOS 26.0, *) {
            // Let the current OS own the bottom bar presentation. On Liquid
            // Glass releases this participates in the system bar treatment;
            // older supported systems keep the established native bar below.
            detail()
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    actions()
                        .fixedSize(horizontal: false, vertical: true)
                }
        } else {
            VStack(spacing: 0) {
                detail()
                actions()
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }
}

private struct ReviewSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.identifier = NSUserInterfaceItemIdentifier("PhotoArchiveSidebarMaterial")
        view.material = ReviewVisualStyle.sidebarMaterial
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = ReviewVisualStyle.sidebarMaterial
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

private struct ReviewSidebarDivider: View {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .ignoresSafeArea(.container, edges: .vertical)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                onDragChanged(value.translation.width)
                            }
                            .onEnded { _ in
                                onDragEnded()
                            }
                    )
                    .onHover { hovering in
                        if hovering, !isHovering {
                            NSCursor.resizeLeftRight.push()
                        } else if !hovering, isHovering {
                            NSCursor.pop()
                        }
                        isHovering = hovering
                    }
            }
            .frame(width: 1)
            .zIndex(2)
    }
}

private struct ReviewWindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ReviewWindowChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReviewWindowChromeView)?.applyWindowStyle()
    }
}

private final class ReviewWindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowStyle()
    }

    func applyWindowStyle() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        // Keep the title bar visually continuous with the app-owned sidebar
        // and detail surfaces. The traffic lights remain the standard
        // NSWindow buttons; only the surrounding title-bar material is
        // transparent, matching the appearance used before the native chrome
        // experiment.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        if #unavailable(macOS 15) {
            window.toolbar?.showsBaselineSeparator = false
        }
        removeTrackingSeparator(in: window)

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.titleVisibility = .hidden
            self.removeTrackingSeparator(in: window)
        }
    }

    private func removeTrackingSeparator(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        while let index = toolbar.items.firstIndex(where: { $0 is NSTrackingSeparatorToolbarItem }) {
            toolbar.removeItem(at: index)
        }
    }

}
