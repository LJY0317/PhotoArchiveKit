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

        // Native wheel handling: ordinary wheel remains vertical; Shift moves X.
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: -3, wheel2: 0, wheel3: 0)!
        scroll.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(scroll.contentView.bounds.origin.y > 0)
        precondition(scroll.contentView.bounds.origin.x == 0)
        let oldY = scroll.contentView.bounds.origin.y
        wheel.flags = .maskShift
        scroll.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(scroll.contentView.bounds.origin.x > 0)
        precondition(scroll.contentView.bounds.origin.y == oldY)

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
        let knobBeforeExpansion = dynamicScroll.verticalScroller!.knobProportion
        dynamicModel.height = 5200
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(dynamicScroll.documentView!.frame.height == 5200)
        precondition(dynamicScroll.documentView === dynamicDocumentView)
        precondition(dynamicScroll.contentView.bounds.origin == originBeforeExpansion)
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
        precondition(!bar.isHidden && !bar.isEnabled)
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
        window.setContentSize(NSSize(width: 650, height: 450))
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(embedded.frame.size == NSSize(width: 650, height: 450))
        precondition(!embedded.horizontalScroller!.frame.intersects(embedded.contentView.frame))

        // Reproduce the real window boundary, including split view + action bar.
        let fullRoot = NSHostingView(rootView: ReviewWindowLayout {
            Text("Synthetic sidebar")
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
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

        print("PASS: native scroller geometry, wheel/Shift-wheel, resize, internal SwiftUI height changes, document update, group reset and full-window action-bar clearance")
    }
}
