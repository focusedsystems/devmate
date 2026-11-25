import AppKit
import SwiftUI

/// The system search field. On macOS 27 `NSSearchField` draws as the borderless
/// glass capsule, so no background, border or magnifier is drawn here. Escape
/// and the clear button empty the field and give up the cursor.
struct GlassSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    var controlSize: NSControl.ControlSize = .small
    var onClear: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldAction(_:))
        field.sendsWholeSearchString = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = prompt
        field.controlSize = controlSize
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        field.setAccessibilityLabel(prompt)
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: GlassSearchField?

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent?.text = field.stringValue
        }

        @objc func fieldAction(_ sender: NSSearchField) {
            let cleared = sender.stringValue.isEmpty && !(parent?.text.isEmpty ?? true)
            parent?.text = sender.stringValue
            if cleared {
                sender.window?.makeFirstResponder(nil)
                parent?.onClear()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            control.stringValue = ""
            parent?.text = ""
            control.window?.makeFirstResponder(nil)
            parent?.onClear()
            return true
        }
    }
}
