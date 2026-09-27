import AppKit
import SwiftUI

struct ReviewRootListEntry: Equatable {
    let id: String
    let title: String
    let subtitle: String
    let selected: Bool
    let toggleEnabled: Bool
    let purposeIndex: Int?
}

/// Native cells let NSTableView own mouse tracking, insertion feedback and autoscroll.
struct ReviewRootList: NSViewRepresentable {
    let entries: [ReviewRootListEntry]
    let isEnabled: Bool
    let onToggle: (String, Bool) -> Void
    var onPurpose: ((String, Int) -> Void)? = nil
    var onSync: ((String) -> Void)? = nil
    var onRemove: ((String) -> Void)? = nil
    var purposeDescriptions: [String] = []
    let onReorder: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let compact = onPurpose == nil
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.autoresizingMask = [.width]
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: compact ? 2 : 4)
        table.rowHeight = compact ? 36 : 52
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder")))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([Coordinator.pasteboardType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let changed = context.coordinator.parent.entries != entries
            || context.coordinator.parent.isEnabled != isEnabled
        context.coordinator.parent = self
        if changed { (scroll.documentView as? NSTableView)?.reloadData() }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let pasteboardType = NSPasteboard.PasteboardType("io.photoarchivekit.root-order")
        var parent: ReviewRootList
        init(_ parent: ReviewRootList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.entries.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let entry = parent.entries[row]
            let cell = NSTableCellView()
            let title = RootDragTextField(labelWithString: entry.title)
            title.font = .systemFont(ofSize: 13, weight: entry.purposeIndex == nil ? .regular : .semibold)
            title.lineBreakMode = .byTruncatingTail
            let subtitle = RootDragTextField(labelWithString: entry.subtitle)
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            subtitle.lineBreakMode = .byTruncatingMiddle
            for text in [title, subtitle] {
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                text.toolTip = "드래그하여 순서 변경"
            }
            let labels = NSStackView(views: [title, subtitle])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.distribution = .fill
            labels.spacing = 2
            labels.identifier = NSUserInterfaceItemIdentifier("root-labels")
            // The labels are the only flexible part of a row. AppKit otherwise
            // has several equally valid views to stretch and may give the spare
            // width to the checkbox, leaving the folder name at intrinsic width.
            labels.setContentHuggingPriority(.init(1), for: .horizontal)
            labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var views: [NSView]
            if let index = entry.purposeIndex {
                let selection = comparisonCheckbox(for: entry)
                let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "폴더")!)
                icon.contentTintColor = .secondaryLabelColor
                icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
                preserveIntrinsicWidth(icon)
                let purpose = NSPopUpButton()
                purpose.addItems(withTitles: ["기본", "장기 보관", "읽기 전용"])
                purpose.selectItem(at: index)
                for (itemIndex, description) in parent.purposeDescriptions.enumerated() {
                    purpose.item(at: itemIndex)?.toolTip = description
                }
                if parent.purposeDescriptions.indices.contains(index) {
                    purpose.toolTip = parent.purposeDescriptions[index]
                }
                purpose.identifier = NSUserInterfaceItemIdentifier(entry.id)
                purpose.target = self
                purpose.action = #selector(purposeChanged(_:))
                purpose.isEnabled = parent.isEnabled
                purpose.widthAnchor.constraint(equalToConstant: 120).isActive = true
                preserveIntrinsicWidth(purpose)
                purpose.setAccessibilityLabel("\(entry.title) 용도")
                let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "등록 해제")!,
                                      target: self, action: #selector(removeClicked(_:)))
                remove.identifier = NSUserInterfaceItemIdentifier(entry.id)
                remove.isBordered = false
                remove.isEnabled = parent.isEnabled
                remove.toolTip = "등록 해제"
                preserveIntrinsicWidth(remove)
                views = [selection, icon, labels, purpose]
                if parent.onSync != nil {
                    let sync = NSButton(
                        image: NSImage(
                            systemSymbolName: "arrow.triangle.2.circlepath",
                            accessibilityDescription: "동기화 연결"
                        )!,
                        target: self,
                        action: #selector(syncClicked(_:))
                    )
                    sync.identifier = NSUserInterfaceItemIdentifier(entry.id)
                    sync.isBordered = false
                    sync.isEnabled = parent.isEnabled
                    sync.toolTip = "동기화 연결…"
                    preserveIntrinsicWidth(sync)
                    views.append(sync)
                }
                views.append(remove)
            } else {
                let selection = comparisonCheckbox(for: entry)
                views = [selection, labels]
            }
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.distribution = .fill
            stack.spacing = entry.purposeIndex == nil ? 6 : 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            let horizontalInset: CGFloat = entry.purposeIndex == nil ? 2 : 4
            NSLayoutConstraint.activate([
                title.widthAnchor.constraint(equalTo: labels.widthAnchor),
                subtitle.widthAnchor.constraint(equalTo: labels.widthAnchor),
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: horizontalInset),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -horizontalInset),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = title
            return cell
        }
        private func comparisonCheckbox(for entry: ReviewRootListEntry) -> NSButton {
            let selection = NSButton(
                checkboxWithTitle: "",
                target: self,
                action: #selector(selectionChanged(_:))
            )
            selection.identifier = NSUserInterfaceItemIdentifier(entry.id)
            selection.state = entry.selected ? .on : .off
            selection.isEnabled = parent.isEnabled && entry.toggleEnabled
            preserveIntrinsicWidth(selection)
            selection.setAccessibilityLabel("\(entry.title) 비교에 포함")
            return selection
        }
        private func preserveIntrinsicWidth(_ view: NSView) {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        @objc private func selectionChanged(_ sender: NSButton) {
            guard let id = sender.identifier?.rawValue else { return }
            parent.onToggle(id, sender.state == .on)
        }
        @objc private func purposeChanged(_ sender: NSPopUpButton) {
            guard let id = sender.identifier?.rawValue else { return }
            parent.onPurpose?(id, sender.indexOfSelectedItem)
        }
        @objc private func syncClicked(_ sender: NSButton) {
            guard let id = sender.identifier?.rawValue else { return }
            parent.onSync?(id)
        }
        @objc private func removeClicked(_ sender: NSButton) {
            guard let id = sender.identifier?.rawValue else { return }
            parent.onRemove?(id)
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.isEnabled, parent.entries.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(parent.entries[row].id, forType: Self.pasteboardType)
            return item
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.isEnabled, (info.draggingSource as? NSTableView) === tableView,
                  let id = info.draggingPasteboard.string(forType: Self.pasteboardType),
                  parent.entries.contains(where: { $0.id == id }) else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent.isEnabled, (info.draggingSource as? NSTableView) === tableView,
                  let id = info.draggingPasteboard.string(forType: Self.pasteboardType),
                  let next = reorderedRootIDs(parent.entries.map(\.id), moving: id, before: row) else { return false }
            parent.onReorder(next)
            return true
        }
    }
}

/// Labels forward tracking to the table; controls retain their own mouse handling.
final class RootDragTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                table.mouseDown(with: event)
                return
            }
            ancestor = view.superview
        }
        super.mouseDown(with: event)
    }
}

func reorderedRootIDs(_ ids: [String], moving id: String, before row: Int) -> [String]? {
    guard let source = ids.firstIndex(of: id), (0...ids.count).contains(row) else { return nil }
    var next = ids
    next.remove(at: source)
    next.insert(id, at: row > source ? row - 1 : row)
    return next == ids ? nil : next
}
