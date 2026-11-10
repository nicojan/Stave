import Foundation

/// What asked for the archive.
public enum ArchiveTrigger: Sendable, Equatable {
    /// A mouse click on the archive button.
    case pointer
    /// Space or Return on the archive button, or an assistive-technology press (no mouse event behind it).
    case keyboard
    /// The command bar's Show Archive row.
    case command
    /// The View ▸ Show Archive menu item.
    case menu
}

/// How the archive is shown. A popover does not take the keyboard when it is opened without the mouse (its window never becomes key), so
/// everything but a mouse click gets a sheet, which does.
public enum ArchivePresentation: Sendable, Equatable {
    case popover, sheet

    public static func presentation(for trigger: ArchiveTrigger) -> ArchivePresentation {
        trigger == .pointer ? .popover : .sheet
    }

    /// The trigger behind a button press: a mouse event means the pointer; a key event, or no event at all (an accessibility press), does not.
    public static func trigger(eventIsPointer: Bool) -> ArchiveTrigger { eventIsPointer ? .pointer : .keyboard }

    public static let menuItem = "Show Archive"
    public static let closeButton = "Close"
}
