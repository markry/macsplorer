import AppKit

/// The path/address text field. When focus arrives via the keyboard (Tab),
/// place the insertion point at the end instead of selecting all — so you can
/// keep typing/extending the path. Mouse clicks are left alone (the cursor goes
/// where you click).
final class AddressTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, NSApp.currentEvent?.type == .keyDown, let editor = currentEditor() {
            let end = (stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
        return ok
    }
}

/// A field editor for the address field that reports when a completion is
/// *committed* (Enter/Tab/click) and how, so the controller can navigate on
/// Return rather than merely filling the field.
final class AddressFieldEditor: NSTextView {
    /// Called on commit with the `NSTextMovement` raw value that triggered it.
    var onCommit: ((Int) -> Void)?

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                   movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag { onCommit?(movement) }
    }
}
