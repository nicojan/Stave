import Foundation

/// What the drag pasteboard's change count says about the drag the sidebar is remembering.
public enum DragSessionVerdict: Sendable, Equatable {
    /// No count recorded yet: this is the first look after the drag began, so record the current one.
    case record
    /// Same count as when recorded: still the drag the sidebar started.
    case live
    /// A different count: another drag wrote the pasteboard (another app, another window), so the remembered item must be forgotten.
    case foreign
}

public enum DragSessionRule {
    /// Binds the sidebar's remembered drag to one pasteboard session. `recorded` is the count seen at the first look after the drag began.
    public static func verdict(recorded: Int?, current: Int) -> DragSessionVerdict {
        guard let recorded else { return .record }
        return recorded == current ? .live : .foreign
    }
}
