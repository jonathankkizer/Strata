import CoreGraphics
import Foundation

/// Geometry policy for the Miller-columns browser: how wide a column may be, and how
/// wide it needs to be to show a name in full.
///
/// Pure arithmetic with no AppKit, so the rules that decide what the user can drag a
/// column to are testable without a window.
enum ColumnLayout {

    /// The width a column opens at before the user has ever resized one.
    static let defaultWidth: CGFloat = 260

    /// Narrow enough to fit several columns on screen, wide enough that a name still
    /// has somewhere to go after the icon and chevron.
    static let minimumWidth: CGFloat = 140

    /// A column past this is no longer a column — it's the list view with extra steps.
    static let maximumWidth: CGFloat = 700

    /// Everything in a row that is not the name itself: the leading inset, the icon and
    /// its gap, the gap before the disclosure chevron, the chevron, and the clearance
    /// the chevron keeps from the overlay scroller. Kept in step with
    /// `ColumnNameCellView`'s constraints.
    static let rowChrome: CGFloat = 4 + 16 + 6 + 4 + 11 + 16

    /// The 1pt separator that sits at a column's trailing edge, outside its content.
    static let separatorWidth: CGFloat = 1

    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    /// The width that would show the longest name in a column without truncating,
    /// clamped to what a column is allowed to be.
    static func widthToFit(longestNameWidth: CGFloat) -> CGFloat {
        clamp((longestNameWidth + rowChrome).rounded(.up))
    }

    /// Interprets a persisted width. A missing preference reads back as 0, and a value
    /// written by a different build could be anything, so neither is trusted.
    static func restored(_ stored: CGFloat) -> CGFloat {
        guard stored > 0, stored.isFinite else { return defaultWidth }
        return clamp(stored)
    }
}
