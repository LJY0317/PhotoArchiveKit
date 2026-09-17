import AppKit
import SwiftUI

@MainActor
private final class DynamicHeightModel: ObservableObject {
    @Published var height: CGFloat = 1200
}

@MainActor
private func fixture(width: CGFloat, height: CGFloat) -> some View {
    Grid {
        ForEach(0..<20) { row in
            GridRow {
                ForEach(0..<4) { column in
                    Text("Synthetic \(row) / \(column)").frame(width: width / 4)
                }
            }
        }
    }
    .frame(width: width, height: height)
}

@MainActor
private struct DynamicHeightFixture: View {
    @ObservedObject var model: DynamicHeightModel
    let width: CGFloat

    var body: some View {
        fixture(width: width, height: model.height)
    }
}

@MainActor
private func findSubview(named className: String, in root: NSView) -> NSView? {
    if String(describing: type(of: root)) == className {
        return root
    }
    for subview in root.subviews {
        if let match = findSubview(named: className, in: subview) {
            return match
        }
    }
    return nil
}

@MainActor
private func findSubview(identifier: String, in root: NSView) -> NSView? {
    if root.identifier?.rawValue == identifier {
        return root
    }
    for subview in root.subviews {
        if let match = findSubview(identifier: identifier, in: subview) {
            return match
        }
    }
    return nil
}

@MainActor
private func findAncestor(identifier: String, from view: NSView) -> NSView? {
    var ancestor = view.superview
    while let current = ancestor {
        if current.identifier?.rawValue == identifier {
            return current
        }
        ancestor = current.superview
    }
    return nil
}

@MainActor
private func assertTopFade(
    _ scrollView: NSScrollView,
    occlusionHeight: CGFloat,
    fadeLength: CGFloat
) {
    guard let gradient = scrollView.contentView.layer?.mask as? CAGradientLayer else {
        preconditionFailure("scroll content is missing its top fade gradient")
    }
    let height = scrollView.contentView.bounds.height
    let occlusion = min(occlusionHeight, height)
    let fade = min(fadeLength, occlusion)
    let fadeStart = max(0, occlusion - fade)
    let locations = gradient.locations?.compactMap { CGFloat(truncating: $0) } ?? []
    precondition(locations.count == 4)
    precondition(abs(locations[0]) < 0.0001)
    precondition(abs(locations[1] - fadeStart / height) < 0.0001)
    precondition(abs(locations[2] - occlusion / height) < 0.0001)
    precondition(abs(locations[3] - 1) < 0.0001)
    precondition(gradient.startPoint.x == 0.5 && gradient.endPoint.x == 0.5)
    if scrollView.contentView.isFlipped {
        precondition(gradient.startPoint.y == 0 && gradient.endPoint.y == 1)
    } else {
        precondition(gradient.startPoint.y == 1 && gradient.endPoint.y == 0)
    }
}

@main
struct ComparisonScrollSelfTest {
    @MainActor static func main() {
        _ = NSApplication.shared
        let scroll = ComparisonScrollContainer(content: fixture(width: 1600, height: 2400), documentID: "a")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.tile()
        let bar = scroll.horizontalScroller!
        precondition(!bar.isHidden && bar.frame.height > 0)
        precondition(bar.knobProportion > 0 && bar.knobProportion < 1)
        precondition(!bar.frame.intersects(scroll.contentView.frame))
        precondition(scroll.documentView!.frame.width == 1600)
        precondition(scroll.documentView!.frame.height == 2400)
        precondition(scroll.contentView.bounds.origin == .zero)

        // Native NSScrollView owns wheel/Shift-wheel behavior. Synthetic
        // CGEvent wheel delivery is ignored by headless AppKit on current macOS,
        // so verify that both native scroll axes accept and preserve positions
        // without trying to re-test AppKit's event routing here.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(scroll.contentView.bounds.origin == NSPoint(x: 0, y: 900))
        scroll.contentView.scroll(to: NSPoint(x: 500, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(scroll.contentView.bounds.origin == NSPoint(x: 500, y: 900))

        scroll.contentView.scroll(to: NSPoint(x: 500, y: 900))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.update(content: fixture(width: 1600, height: 2400), documentID: "a")
        precondition(scroll.contentView.bounds.origin == NSPoint(x: 500, y: 900))

        // Internal SwiftUI state can change the hosted document height without
        // NSViewRepresentable receiving a new root content value. The scroll
        // container must follow intrinsic-size invalidation in both directions.
        let dynamicModel = DynamicHeightModel()
        let dynamicScroll = ComparisonScrollContainer(
            content: DynamicHeightFixture(model: dynamicModel, width: 1600),
            documentID: "dynamic"
        )
        window.contentView = dynamicScroll
        window.setContentSize(NSSize(width: 800, height: 600))
        dynamicScroll.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(dynamicScroll.documentView!.frame.height == 1200)
        let dynamicDocumentView = dynamicScroll.documentView!
        dynamicScroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        dynamicScroll.reflectScrolledClipView(dynamicScroll.contentView)
        let originBeforeExpansion = dynamicScroll.contentView.bounds.origin
        let documentFrameBeforeExpansion = dynamicDocumentView.frame
        let knobBeforeExpansion = dynamicScroll.verticalScroller!.knobProportion
        dynamicModel.height = 5200
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(dynamicScroll.documentView!.frame.height == 5200)
        precondition(dynamicScroll.documentView === dynamicDocumentView)
        precondition(dynamicScroll.contentView.bounds.origin == originBeforeExpansion)
        precondition(dynamicScroll.documentView!.frame.origin == documentFrameBeforeExpansion.origin)
        precondition(dynamicScroll.verticalScroller!.knobProportion < knobBeforeExpansion)
        let dynamicMaxY = dynamicScroll.documentView!.frame.height - dynamicScroll.contentView.bounds.height
        dynamicScroll.contentView.scroll(to: NSPoint(x: 0, y: dynamicMaxY))
        dynamicScroll.reflectScrolledClipView(dynamicScroll.contentView)
        precondition(dynamicScroll.contentView.bounds.origin.y > 4000)
        dynamicScroll.contentView.scroll(to: .zero)
        dynamicScroll.reflectScrolledClipView(dynamicScroll.contentView)
        precondition(dynamicScroll.contentView.bounds.origin.y == 0)
        dynamicScroll.contentView.scroll(to: NSPoint(x: 0, y: dynamicMaxY))
        dynamicScroll.reflectScrolledClipView(dynamicScroll.contentView)
        precondition(dynamicScroll.contentView.bounds.origin.y > 4000)
        dynamicModel.height = 1200
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(dynamicScroll.documentView!.frame.height == 1200)
        let collapsedMaxY = max(0, 1200 - dynamicScroll.contentView.bounds.height)
        precondition(dynamicScroll.contentView.bounds.origin.y <= collapsedMaxY)
        dynamicScroll.contentView.scroll(to: .zero)
        dynamicScroll.reflectScrolledClipView(dynamicScroll.contentView)
        precondition(dynamicScroll.contentView.bounds.origin.y == 0)

        window.setContentSize(NSSize(width: 600, height: 400))
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        scroll.tile()
        precondition(!bar.isHidden && bar.knobProportion < 0.4)
        precondition(!bar.frame.intersects(scroll.contentView.frame))

        // Replacing a group must reset both axes and adopt the new document size.
        scroll.update(content: fixture(width: 700, height: 1200), documentID: "b")
        precondition(scroll.documentView!.frame.size == NSSize(width: 700, height: 1200))
        precondition(scroll.contentView.bounds.origin == .zero)
        window.setContentSize(NSSize(width: 1800, height: 1400))
        scroll.layoutSubtreeIfNeeded()
        scroll.tile()
        precondition(!scroll.hasHorizontalScroller)
        precondition(abs(scroll.contentView.frame.minY - scroll.bounds.minY) < 0.5)
        precondition(scroll.contentView.bounds.origin == .zero)
        // Exercise NSViewRepresentable inside a SwiftUI viewport as in the app.
        let root = NSHostingView(rootView: GeometryReader { proxy in
            ReviewComparisonScrollView(documentID: "embedded") {
                fixture(width: max(1600, proxy.size.width - 17), height: 2400)
            }
        })
        window.contentView = root
        window.setContentSize(NSSize(width: 800, height: 600))
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        let embedded = findScroll(root)!
        precondition(embedded.frame.size == NSSize(width: 800, height: 600))
        precondition(embedded.documentView!.frame.width == 1600)
        precondition(!embedded.horizontalScroller!.isHidden)
        precondition(embedded.contentView.layer?.mask == nil)
        embedded.contentView.scroll(to: NSPoint(x: 0, y: 120))
        embedded.reflectScrolledClipView(embedded.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assertTopFade(
            embedded,
            occlusionHeight: ReviewScrollEdgeFade.defaultLength,
            fadeLength: ReviewScrollEdgeFade.defaultLength
        )
        window.setContentSize(NSSize(width: 650, height: 450))
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(embedded.frame.size == NSSize(width: 650, height: 450))
        precondition(!embedded.horizontalScroller!.frame.intersects(embedded.contentView.frame))

        // Reproduce the real window boundary, including the app-owned sidebar
        // shell and action bar. The sidebar no longer relies on
        // NavigationSplitView's private source-list edge composition.
        let fullRoot = NSHostingView(rootView: ReviewWindowLayout {
            Text("Synthetic sidebar")
        } detail: {
            GeometryReader { proxy in
                ReviewComparisonScrollView(documentID: "window") {
                    fixture(width: 1600, height: 2400)
                }
            }
        } actions: {
            Text("Synthetic actions").frame(maxWidth: .infinity).frame(height: 44)
        })
        window.contentView = fullRoot
        window.setContentSize(NSSize(width: 1100, height: 750))
        fullRoot.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(
            findSubview(named: "_NSSplitViewShadowView", in: fullRoot) == nil,
            "app-owned sidebar shell must not create NavigationSplitView's private edge shadow"
        )
        guard let sidebarMaterial = findSubview(
            identifier: "PhotoArchiveSidebarMaterial",
            in: fullRoot
        ) as? NSVisualEffectView else {
            preconditionFailure("semantic sidebar material was not installed")
        }
        precondition(sidebarMaterial.material == ReviewVisualStyle.sidebarMaterial)
        precondition(sidebarMaterial.blendingMode == .behindWindow)
        for size in [NSSize(width: 1100, height: 750), NSSize(width: 980, height: 640),
                     NSSize(width: 1500, height: 900)] {
            window.setContentSize(size)
            fullRoot.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let fullScroll = findScroll(fullRoot)!
            let fullBar = fullScroll.horizontalScroller!
            let barInWindow = fullBar.convert(fullBar.bounds, to: nil)
            precondition(barInWindow.minY >= 44, "Horizontal scroller is behind the action bar")
            precondition(barInWindow.maxY <= size.height)
            precondition(fullBar.visibleRect.height == fullBar.bounds.height)
            precondition(fullBar.visibleRect.width == fullBar.bounds.width)
            precondition(!fullBar.isHidden && fullBar.isEnabled)
        }

        // A detail that fits horizontally must reach the action bar directly;
        // there is no disabled horizontal-scroller slot left as a blank strip.
        let noOverflowRoot = NSHostingView(rootView: ReviewWindowLayout {
            Text("Synthetic sidebar")
        } detail: {
            ReviewComparisonScrollView(documentID: "no-overflow") {
                fixture(width: 500, height: 1200)
            }
        } actions: {
            Text("Synthetic actions").frame(maxWidth: .infinity).frame(height: 44)
        })
        window.contentView = noOverflowRoot
        window.setContentSize(NSSize(width: 1500, height: 900))
        noOverflowRoot.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let noOverflowScroll = findScroll(noOverflowRoot)!
        precondition(!noOverflowScroll.hasHorizontalScroller)
        let clipInWindow = noOverflowScroll.contentView.convert(noOverflowScroll.contentView.bounds, to: nil)
        precondition(abs(clipInWindow.minY - 44) < 1)

        // The app-owned sidebar uses a normal SwiftUI ScrollView, but the
        // actual NSScrollView lives inside a semantic NSVisualEffectView so the
        // native overlay scroller's expanded drag track inherits sidebar
        // material instead of falling back to the white window surface.
        let sidebarShellRoot = NSHostingView(rootView: ReviewWindowLayout {
            ReviewSidebarScrollView {
                LazyVStack {
                    ForEach(0..<40) { row in
                        Text("Sidebar row \(row)")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
        } detail: {
            Color.white
        } actions: {
            EmptyView()
        })
        window.contentView = sidebarShellRoot
        window.setContentSize(NSSize(width: 1100, height: 750))
        sidebarShellRoot.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        precondition(findSubview(named: "_NSSplitViewShadowView", in: sidebarShellRoot) == nil)
        precondition(findSubview(named: "NSTableView", in: sidebarShellRoot) == nil)
        guard let sidebarScroll = findScroll(sidebarShellRoot) else {
            preconditionFailure("app-owned sidebar ScrollView was not found")
        }
        precondition(sidebarScroll.documentView != nil)
        precondition(sidebarScroll.scrollerStyle == .overlay)
        guard let sidebarScrollMaterial = findAncestor(
            identifier: "PhotoArchiveSidebarScrollMaterial",
            from: sidebarScroll
        ) as? NSVisualEffectView else {
            preconditionFailure("sidebar NSScrollView must be a descendant of semantic sidebar material")
        }
        precondition(sidebarScrollMaterial.material == ReviewVisualStyle.sidebarMaterial)
        precondition(sidebarScrollMaterial.blendingMode == .behindWindow)
        precondition(
            ReviewSidebarLayoutMetrics.rowTrailingInset
                > NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay),
            "sidebar row selection background must clear the native overlay scroller lane"
        )
        precondition(
            abs(sidebarScroll.contentView.frame.width - sidebarScroll.bounds.width) < 0.5,
            "app-owned sidebar must not reserve a legacy scroller gutter"
        )
        precondition(sidebarScroll.backgroundColor == .clear || !sidebarScroll.drawsBackground)
        precondition(sidebarScroll.contentView.layer?.mask == nil)
        sidebarScroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        sidebarScroll.reflectScrolledClipView(sidebarScroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        assertTopFade(
            sidebarScroll,
            occlusionHeight: ReviewScrollEdgeFade.defaultLength,
            fadeLength: ReviewScrollEdgeFade.defaultLength
        )
        precondition(
            sidebarScroll.verticalScroller?.layer?.mask == nil,
            "native sidebar scroller must not be masked"
        )

        print("PASS: native comparison scroller geometry and axes, conditional horizontal overflow, resize, internal SwiftUI height changes, document update, group reset, full-window action-bar clearance, semantic app-owned sidebar/scroller material and no NavigationSplitView private gutter")
    }
}
