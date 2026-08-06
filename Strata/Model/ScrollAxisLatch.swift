import CoreGraphics

/// Decides whether a scroll gesture belongs to the enclosing scroll view rather than to
/// the one the pointer is over — and then holds that decision for the whole gesture.
///
/// The columns browser nests a vertically-scrolling column inside a horizontally-
/// scrolling strip, and a trackpad swipe is never purely one axis. Deciding per event
/// would let a sideways swipe that drifts a few points vertically hop between the two
/// scroll views mid-gesture; latching at the start is what makes it feel like one
/// continuous movement.
///
/// Pure state machine, no AppKit: the view's job is only to classify events into `Step`.
struct ScrollAxisLatch {

    /// An incoming scroll event, reduced to what the decision depends on.
    enum Step {
        /// A trackpad gesture began. The axis is decided here.
        case begins(deltaX: CGFloat, deltaY: CGFloat)
        /// The gesture continues, including the momentum that follows the fingers lifting.
        case `continues`
        /// The gesture ended.
        case ends
        /// A discrete wheel notch, which stands alone — there is no gesture to latch to.
        case standalone(deltaX: CGFloat, deltaY: CGFloat)
    }

    private(set) var routesToEnclosing = false

    /// Returns where this event should go. The closing event of a gesture still goes
    /// where the rest of it went: a scroll view that never sees a gesture end keeps its
    /// rubber-banding.
    mutating func route(_ step: Step) -> Bool {
        switch step {
        case .begins(let deltaX, let deltaY), .standalone(let deltaX, let deltaY):
            // A tie stays with the column. Vertical is what a list is for, and a
            // gesture ambiguous enough to tie is not a deliberate sideways swipe.
            routesToEnclosing = abs(deltaX) > abs(deltaY)
        case .continues:
            break
        case .ends:
            defer { routesToEnclosing = false }
            return routesToEnclosing
        }
        return routesToEnclosing
    }
}
