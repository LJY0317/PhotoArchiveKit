import AppKit
import SwiftUI

struct ReviewToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    @Binding var isFocused: Bool
    let onMoveDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onMoveDown: onMoveDown)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(frame: .zero)
        searchField.delegate = context.coordinator
        searchField.placeholderString = prompt
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .regular
        searchField.stringValue = text
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.onMoveDown = onMoveDown
        nsView.placeholderString = prompt
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if isFocused, nsView.currentEditor() == nil {
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView,
                      context.coordinator.isFocused.wrappedValue,
                      nsView.currentEditor() == nil
                else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        } else if !isFocused, nsView.currentEditor() != nil {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onMoveDown: () -> Void

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onMoveDown: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onMoveDown = onMoveDown
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            setFocused(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            setFocused(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.moveDown(_:)) else { return false }
            onMoveDown()
            return true
        }

        private func setFocused(_ focused: Bool) {
            if isFocused.wrappedValue != focused {
                isFocused.wrappedValue = focused
            }
        }
    }
}
