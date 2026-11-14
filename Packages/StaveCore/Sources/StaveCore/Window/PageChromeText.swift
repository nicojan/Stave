import Foundation

/// The words around a page and the window's chrome that views and the app would otherwise spell out themselves: the loading bar's
/// VoiceOver label and value, the empty content area, the sidebar's width handle, the app's own menu items and alert buttons.
public enum PageChromeText {
    /// The loading bar's VoiceOver label.
    public static let loadingLabel = "Loading"
    /// The content area with no tab selected.
    public static let noSelection = "No tab selected"
    /// Settings while the store is not open.
    public static let dataNotOpen = "Stave's data is not open."
    /// The sidebar's width handle, for VoiceOver.
    public static let sidebarWidth = "Sidebar width"

    /// The loading bar's VoiceOver value: "‹n› percent", 0 to 100. A fraction outside 0…1 is clamped; NaN reads as 0.
    public static func progressValue(_ fraction: Double) -> String {
        "\(Int(clamped(fraction.isNaN ? 0 : fraction, to: 0...1) * 100)) percent"
    }

    /// The width handle's VoiceOver value: "‹n› points", whole points. Not a number reads as 0.
    public static func sidebarWidthValue(_ points: Double) -> String {
        "\(Int(clamped(points.isNaN ? 0 : points, to: 0...maxPoints))) points"
    }

    // MARK: - App menus and alerts

    public static let quitMenuItem = "Quit Stave"
    public static let newWindowMenuItem = "New Window"
    public static let closeTabMenuItem = "Close Tab"
    public static let closeWindowMenuItem = "Close Window"
    /// The Tab menu's title.
    public static let tabMenu = "Tab"
    /// Tab ▸ Move to Workspace, and the same submenu in a tab row's context menu.
    public static let moveToWorkspaceMenu = "Move to Workspace"
    public static let okButton = "OK"
    public static let quitButton = "Quit"

    /// Far beyond any screen; keeps `Int(_:)` away from values it would trap on.
    private static let maxPoints = 1_000_000.0

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
