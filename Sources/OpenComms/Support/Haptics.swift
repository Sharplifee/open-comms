import UIKit

/// The phone is in a pocket, so anything worth knowing has to be felt.
/// Generators are prepared before firing — an unprepared one lags noticeably
/// on the first hit, which defeats the point.
enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let g = UIImpactFeedbackGenerator(style: style); g.prepare(); g.impactOccurred()
    }
    static func select() {
        let g = UISelectionFeedbackGenerator(); g.prepare(); g.selectionChanged()
    }
}
