import Foundation

/// Page zoom per site (decision 12): ⌘+ and ⌘- step through Safari's levels, ⌘0 goes back to 100 %. Only a level other than 100 % is
/// stored, as a site value (`SiteValueKey.zoom`).
public enum ZoomLevels {
    /// Safari's levels, as `WKWebView.pageZoom` factors.
    public static let levels: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    public static let defaultLevel = 1.0
    public static var smallest: Double { levels[0] }
    public static var largest: Double { levels[levels.count - 1] }
    /// Two zoom factors closer than this are one level (`pageZoom` is a CGFloat and a stored value goes through text).
    private static let tolerance = 0.001

    /// The next level up; the largest stays where it is. A level between two steps moves to the next step above it.
    public static func next(after level: Double) -> Double {
        levels.first { $0 > level + tolerance } ?? largest
    }

    /// The next level down; the smallest stays where it is.
    public static func previous(before level: Double) -> Double {
        levels.last { $0 < level - tolerance } ?? smallest
    }

    public static func isDefault(_ level: Double) -> Bool {
        abs(level - defaultLevel) < tolerance
    }

    public static func canZoomIn(from level: Double) -> Bool { level < largest - tolerance }
    public static func canZoomOut(from level: Double) -> Bool { level > smallest + tolerance }

    /// What is stored for `level`: nil (no row) at 100 %.
    public static func storedValue(_ level: Double) -> Double? {
        isDefault(level) ? nil : level
    }

    /// The level a page gets from a stored value: 100 % when there is none or it isn't a number, otherwise clamped to Safari's range.
    public static func sanitized(_ stored: Double?) -> Double {
        guard let stored, stored.isFinite else { return defaultLevel }
        return min(max(stored, smallest), largest)
    }
}
