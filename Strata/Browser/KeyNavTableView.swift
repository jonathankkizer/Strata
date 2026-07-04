import AppKit

/// An NSTableView that surfaces the Finder navigation keys the plain control
/// doesn't: ⌘↓ to open the selection, and — in the columns browser — ←/→ to move
/// between columns. Plain ↑/↓ selection is left to the superclass.
final class KeyNavTableView: NSTableView {

    /// ⌘↓ — open (descend into) the selected item.
    var onCommandDown: (() -> Void)?
    /// ← — move focus to the parent column (columns browser only).
    var onArrowLeft: (() -> Void)?
    /// → — move into the selected folder's column (columns browser only).
    var onArrowRight: (() -> Void)?

    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    /// The "real" modifiers — arrow keys always also carry .function and
    /// .numericPad, which would otherwise break exact modifier matches.
    private static let realModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.realModifiers)
        let chars = event.charactersIgnoringModifiers

        if flags == .command, chars == Self.downArrow, let onCommandDown {
            onCommandDown()
            return
        }
        if flags.isEmpty, chars == Self.leftArrow, let onArrowLeft {
            onArrowLeft()
            return
        }
        if flags.isEmpty, chars == Self.rightArrow, let onArrowRight {
            onArrowRight()
            return
        }
        super.keyDown(with: event)
    }
}
