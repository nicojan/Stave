import Foundation

/// How a browser window is laid out in and out of compact mode. Normally the content runs under the transparent title bar, beside the
/// sidebar and its divider, and the traffic lights sit over the sidebar. Compact mode hides only the sidebar (Nico, 2026-11-09, matching
/// Zen): the window keeps a title bar of its own, so the traffic lights never sit over the page, and the content takes the full width
/// below it. The sidebar, when it slides in, starts below that bar too.
public enum CompactLayout {
    /// The sidebar's top padding when the traffic lights sit over it.
    static let trafficLightClearance: Double = 28
    /// The sidebar's top padding below a title bar of its own.
    static let margin: Double = 8

    /// True when the content runs under the title bar (the window's full-size content view); false when the title bar is a bar of its own.
    public static func contentUnderTitleBar(isCompact: Bool) -> Bool { !isCompact }

    /// Points from the left of the window to the left of the content.
    public static func contentLeading(isCompact: Bool, sidebarWidth: Double, dividerWidth: Double) -> Double {
        isCompact ? 0 : sidebarWidth + dividerWidth
    }

    /// The sidebar's top padding.
    public static func sidebarTop(isCompact: Bool) -> Double { isCompact ? margin : trafficLightClearance }
}
