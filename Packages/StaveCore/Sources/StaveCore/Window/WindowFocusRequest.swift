import Foundation

/// Where a browser window's keyboard focus should go next, as the model asks for it; the window controller and views honour it.
public enum WindowFocusTarget: Equatable, Sendable {
    /// The selected tab's web view. A window with no page for it leaves the focus where it is.
    case page
    /// The History view's search field, whatever held the focus before (a sidebar list, a web view).
    case historySearch
}

/// One focus request. The serial makes a repeat of the same target a new value, so it is honoured again.
public struct WindowFocusRequest: Equatable, Sendable {
    public let target: WindowFocusTarget
    public let serial: Int

    public init(target: WindowFocusTarget, serial: Int) {
        self.target = target
        self.serial = serial
    }
}
