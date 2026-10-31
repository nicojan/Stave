import CoreGraphics
import Foundation

/// Turns a saved window frame string back into a frame that can be shown, or nil when the window should open at the default size, centred.
public enum WindowFrameRestore {
    public static let defaultSize = CGSize(width: 1200, height: 800)
    public static let minimumSize = CGSize(width: 800, height: 500)

    /// nil for an empty, unparseable, zero-area, NaN or infinite string. Otherwise the frame grown to the minimum size where it is smaller,
    /// then moved onto a screen by `WindowFrameClamp` (which may shrink it again when a screen is smaller than the minimum).
    public static func restore(_ saved: String, visibleFrames: [CGRect]) -> CGRect? {
        guard let rect = parse(saved) else { return nil }
        let grown = CGRect(
            x: rect.minX, y: rect.minY,
            width: max(rect.width, minimumSize.width), height: max(rect.height, minimumSize.height)
        )
        return WindowFrameClamp.clamp(grown, visibleFrames: visibleFrames)
    }

    static func parse(_ saved: String) -> CGRect? {
        guard !saved.isEmpty else { return nil }
        let rect = NSRectFromString(saved)
        let numbers = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard numbers.allSatisfy({ $0.isFinite }), rect.size.width > 0, rect.size.height > 0 else { return nil }
        return rect
    }
}
