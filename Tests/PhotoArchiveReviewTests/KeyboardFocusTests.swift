import AppKit
import SwiftUI

@MainActor
private final class SearchFocusModel: ObservableObject {
    @Published var text = ""
    @Published var isFocused = false
    var moveDownCount = 0
}

@MainActor
private struct SearchFocusFixture: View {
    @ObservedObject var model: SearchFocusModel

    var body: some View {
        ReviewToolbarSearchField(
            text: $model.text,
            prompt: "Synthetic search",
            isFocused: $model.isFocused,
            onMoveDown: { model.moveDownCount += 1 }
        )
        .frame(width: 240)
    }
}

@MainActor
private func findSearchField(in root: NSView) -> NSSearchField? {
    if let field = root as? NSSearchField { return field }
    return root.subviews.lazy.compactMap(findSearchField).first
}

private final class FocusTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@main
struct KeyboardFocusSelfTest {
    @MainActor static func main() {
        var focusState = ReviewKeyboardFocusState()
        focusState.enterSearch(
            returningTo: .detail(itemID: "group-1", copyID: "copy-2")
        )
        precondition(focusState.focus == .search)
        precondition(
            focusState.takeSearchReturnTarget()
                == .detail(itemID: "group-1", copyID: "copy-2"),
            "keyboard search entry must remember the exact detail location"
        )
        focusState.focus(.detail)
        focusState.beginDirectSearch()
        precondition(
            focusState.takeSearchReturnTarget() == nil,
            "direct search focus must not reuse an older keyboard return location"
        )
        focusState.focus(.sidebar)
        focusState.enterSearch(returningTo: .sidebar(itemID: "group-3"))
        precondition(
            focusState.takeSearchReturnTarget() == .sidebar(itemID: "group-3"),
            "sidebar search entry must remember the selected row"
        )

        _ = NSApplication.shared
        let model = SearchFocusModel()
        let host = NSHostingView(rootView: SearchFocusFixture(model: model))
        let window = FocusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let searchField = findSearchField(in: host) else {
            preconditionFailure("search field was not created")
        }
        precondition(window.makeFirstResponder(searchField))
        searchField.selectText(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(searchField.currentEditor() != nil)
        guard let coordinator = searchField.delegate as? ReviewToolbarSearchField.Coordinator else {
            preconditionFailure("search field coordinator was not installed")
        }
        coordinator.controlTextDidBeginEditing(
            Notification(name: NSControl.textDidBeginEditingNotification, object: searchField)
        )
        precondition(model.isFocused)

        guard let editor = searchField.currentEditor() as? NSTextView else {
            preconditionFailure("search field editor was not created")
        }
        precondition(
            coordinator.control(
                searchField,
                textView: editor,
                doCommandBy: #selector(NSResponder.moveDown(_:))
            ),
            "the search field must consume the down-arrow command"
        )
        precondition(model.moveDownCount == 1, "down arrow must hand focus to review results")

        model.isFocused = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(searchField.currentEditor() == nil)
        precondition(!model.isFocused)

        model.isFocused = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(searchField.currentEditor() != nil, "programmatic search focus must show the caret")

        print("review keyboard focus self-test passed")
    }
}
