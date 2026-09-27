import AppKit
import SwiftUI

@main
struct RootListTests {
    @MainActor static func main() {
        let ids = ["a", "b", "c", "d"]
        precondition(reorderedRootIDs(ids, moving: "a", before: 4) == ["b", "c", "d", "a"])
        precondition(reorderedRootIDs(ids, moving: "d", before: 0) == ["d", "a", "b", "c"])
        precondition(reorderedRootIDs(ids, moving: "b", before: 3) == ["a", "c", "b", "d"])
        precondition(reorderedRootIDs(ids, moving: "b", before: 1) == nil)
        precondition(reorderedRootIDs(ids, moving: "b", before: 2) == nil)
        precondition(reorderedRootIDs(ids, moving: "foreign", before: 0) == nil)
        precondition(reorderedRootIDs(ids, moving: "a", before: 5) == nil)
        precondition(reorderedRootIDs([], moving: "a", before: 0) == nil)
        let entries = ids.map {
            ReviewRootListEntry(id: $0, title: $0, subtitle: "Synthetic folder", selected: false,
                                toggleEnabled: true, purposeIndex: nil)
        }
        var saved: [String] = []
        var list = ReviewRootList(entries: entries, isEnabled: true, onToggle: { _, _ in },
                                  onReorder: { saved = $0 })
        let coordinator = list.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("folder")))
        table.dataSource = coordinator
        table.delegate = coordinator
        precondition(coordinator.numberOfRows(in: table) == 4)
        let pasteboard = NSPasteboard(name: .init("PhotoArchiveKit.synthetic-root-test"))
        defer { pasteboard.releaseGlobally() }
        let writer = coordinator.tableView(table, pasteboardWriterForRow: 0)!
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects([writer]))
        let drag = TestRootDrag(source: table, pasteboard: pasteboard)
        precondition(coordinator.tableView(table, validateDrop: drag, proposedRow: 4, proposedDropOperation: .above) == .move)
        precondition(coordinator.tableView(table, acceptDrop: drag, row: 4, dropOperation: .above))
        precondition(saved == ["b", "c", "d", "a"])
        let foreign = TestRootDrag(source: NSTableView(), pasteboard: pasteboard)
        precondition(coordinator.tableView(table, validateDrop: foreign, proposedRow: 0, proposedDropOperation: .above).isEmpty)
        precondition(!coordinator.tableView(table, acceptDrop: foreign, row: 0, dropOperation: .above))
        list = ReviewRootList(entries: entries, isEnabled: false, onToggle: { _, _ in }, onReorder: { _ in })
        coordinator.parent = list
        precondition(coordinator.tableView(table, pasteboardWriterForRow: 0) == nil)
        precondition(!coordinator.tableView(table, acceptDrop: drag, row: 4, dropOperation: .above))
        let trackingTable = TrackingTable()
        let cell = coordinator.tableView(trackingTable, viewFor: nil, row: 0)!
        trackingTable.addSubview(cell)
        func findLabel(_ view: NSView) -> RootDragTextField? {
            if let label = view as? RootDragTextField { return label }
            return view.subviews.lazy.compactMap { findLabel($0) }.first
        }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        findLabel(cell)!.mouseDown(with: event)
        precondition(trackingTable.receivedMouseDown, "Folder text must hand drag tracking to NSTableView")

        func findView(_ view: NSView, identifier: String) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            return view.subviews.lazy.compactMap { findView($0, identifier: identifier) }.first
        }
        let popoverList = ReviewRootList(
            entries: [ReviewRootListEntry(
                id: "popover", title: "Pictures", subtitle: "기본",
                selected: true, toggleEnabled: true, purposeIndex: nil
            )],
            isEnabled: true,
            onToggle: { _, _ in },
            onReorder: { _ in }
        )
        let popoverCell = popoverList.makeCoordinator().tableView(table, viewFor: nil, row: 0)!
        popoverCell.frame = NSRect(x: 0, y: 0, width: 280, height: 36)
        popoverCell.layoutSubtreeIfNeeded()
        precondition(
            findView(popoverCell, identifier: "root-labels")!.frame.width > 230,
            "Popover folder labels should receive the row's flexible width"
        )
        precondition(
            popoverCell.subviewsRecursive.contains { $0 is NSButton } &&
                !popoverCell.subviewsRecursive.contains { $0 is NSSwitch },
            "The comparison scope should use a checkbox"
        )
        let popoverCheckbox = popoverCell.subviewsRecursive
            .compactMap { $0 as? NSButton }
            .first { $0.title.isEmpty }!
        precondition(
            popoverCheckbox.toolTip == nil,
            "Comparison checkboxes should not show redundant hover text"
        )

        var managerToggle: (String, Bool)?
        var managerSyncID: String?
        let managerList = ReviewRootList(
            entries: [ReviewRootListEntry(
                id: "manager", title: "Downloads", subtitle: "/Synthetic/Downloads",
                selected: true, toggleEnabled: true, purposeIndex: 0
            )],
            isEnabled: true,
            onToggle: { managerToggle = ($0, $1) },
            onPurpose: { _, _ in },
            onSync: { managerSyncID = $0 },
            onRemove: { _ in },
            purposeDescriptions: ["기본", "장기 보관", "읽기 전용"],
            onReorder: { _ in }
        )
        let managerCoordinator = managerList.makeCoordinator()
        let managerCell = managerCoordinator.tableView(table, viewFor: nil, row: 0)!
        managerCell.frame = NSRect(x: 0, y: 0, width: 610, height: 52)
        managerCell.layoutSubtreeIfNeeded()
        precondition(
            findView(managerCell, identifier: "root-labels")!.frame.width > 270,
            "Manager folder labels should expand while controls keep intrinsic widths"
        )
        precondition(
            managerCell.subviewsRecursive.contains {
                ($0 as? NSButton).map { $0.title.isEmpty && $0.toolTip == nil } == true
            } && !managerCell.subviewsRecursive.contains { $0 is NSSwitch },
            "Folder management should expose the same comparison checkbox without restoring the old active switch"
        )
        let managerCheckbox = managerCell.subviewsRecursive
            .compactMap { $0 as? NSButton }
            .first { $0.title.isEmpty && $0.toolTip == nil }!
        precondition(
            managerCheckbox.toolTip == nil,
            "Manager comparison checkboxes should not show redundant hover text"
        )
        precondition(managerCheckbox.state == .on, "Manager checkbox should reflect selectedRootIDs")
        managerCheckbox.state = .off
        managerCheckbox.performClick(nil)
        precondition(
            managerToggle?.0 == "manager" && managerToggle?.1 == true,
            "Manager checkbox should use the same comparison-scope callback"
        )
        let syncButton = managerCell.subviewsRecursive
            .compactMap { $0 as? NSButton }
            .first { $0.toolTip == "동기화 연결…" }!
        syncButton.performClick(nil)
        precondition(managerSyncID == "manager", "Manager sync action should preserve the root ID")
        print("Review root list tests passed.")
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] {
        subviews + subviews.flatMap(\.subviewsRecursive)
    }
}

@MainActor
private final class TrackingTable: NSTableView {
    var receivedMouseDown = false
    override func mouseDown(with event: NSEvent) { receivedMouseDown = true }
}

@MainActor
private final class TestRootDrag: NSObject, NSDraggingInfo {
    let draggingSource: Any?
    let draggingPasteboard: NSPasteboard
    init(source: NSTableView, pasteboard: NSPasteboard) {
        draggingSource = source
        draggingPasteboard = pasteboard
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
