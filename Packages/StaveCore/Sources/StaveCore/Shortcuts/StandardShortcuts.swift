import Foundation

/// The modifier keys of a shortcut, independent of AppKit and SwiftUI (the app maps them onto `EventModifiers` and `NSEvent`).
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

/// The keys that are not printable characters, written as one character each so every entry's key is one `Character`.
public enum ShortcutKey {
    public static let upArrow = "↑"
    public static let downArrow = "↓"
    public static let tab = "⇥"
}

/// The menu an entry's item sits in.
public enum MenuName: Sendable, Equatable {
    case app, file, edit, view, history, develop, tab, workspaces
}

/// Every command that has a key. The digit cases are 1-based.
public enum ShortcutCommand: Hashable, Sendable {
    case quit, settings
    case newTab, newWindow, newPrivateWindow, openFile, openLocation, closeTab, closeWindow, print
    case find, findNext, findPrevious, useSelectionForFind
    case toggleCompactMode, back, forward, reload, stop, actualSize, zoomIn, zoomOut, showDownloads
    case showAllHistory, reopenClosedTab
    case showWebInspector, showPageSource
    case pinTab, nextTab, previousTab, selectTab(Int), moveRowUp, moveRowDown
    case switchWorkspace(Int)
}

/// One key for one command. A command has at most one shown entry (the key its menu item displays) and may have hidden entries, which the
/// app catches before the menus (a SwiftUI menu item takes one key): alternates of a shown key (⌘=, ⇧⌘], ⇧⌘[) and ⌘1–9, which no menu lists.
public struct ShortcutEntry: Equatable, Sendable {
    public let command: ShortcutCommand
    /// One character: a lowercase letter, a digit, punctuation, or a `ShortcutKey`.
    public let key: String
    public let modifiers: ShortcutModifiers
    public let menu: MenuName
    /// The sheet gate the command obeys (`MenuCommandGate`); nil only for the app's own commands (Quit, Settings).
    public let gate: MenuCommand?
    public let isHidden: Bool

    /// Whether the command may run now: the declared `gate` through `MenuCommandGate`. The menus (`standardShortcut`) and the key monitor both
    /// ask this, so the declaration is the guard. A command with no gate (Quit, Settings) is the app's and always runs.
    public func isEnabled(busy: Bool) -> Bool {
        gate.map { MenuCommandGate.isEnabled($0, busy: busy) } ?? true
    }

    public init(_ command: ShortcutCommand, _ key: String, _ modifiers: ShortcutModifiers, menu: MenuName, gate: MenuCommand?, isHidden: Bool = false) {
        self.command = command; self.key = key; self.modifiers = modifiers; self.menu = menu; self.gate = gate; self.isHidden = isHidden
    }
}

/// Decision 16: every shortcut Stave has, in one table, with Safari's meanings. The menus are built from it, and nothing else assigns a key.
public enum StandardShortcuts {
    public static let all: [ShortcutEntry] = appAndFile + edit + view + historyAndDevelop + tab + workspaces

    private static let appAndFile: [ShortcutEntry] = [
        ShortcutEntry(.quit, "q", .command, menu: .app, gate: nil),
        ShortcutEntry(.settings, ",", .command, menu: .app, gate: nil),
        ShortcutEntry(.newTab, "t", .command, menu: .file, gate: .newTab),
        ShortcutEntry(.newWindow, "n", .command, menu: .file, gate: .newWindow),
        ShortcutEntry(.newPrivateWindow, "n", [.command, .shift], menu: .file, gate: .newWindow),
        ShortcutEntry(.openFile, "o", .command, menu: .file, gate: .newWindow),
        ShortcutEntry(.openLocation, "l", .command, menu: .file, gate: .openLocation),
        ShortcutEntry(.closeTab, "w", .command, menu: .file, gate: .closeTab),
        ShortcutEntry(.closeWindow, "w", [.command, .shift], menu: .file, gate: .closeWindow),
        ShortcutEntry(.print, "p", .command, menu: .file, gate: .pageCommand),
    ]

    private static let edit: [ShortcutEntry] = [
        ShortcutEntry(.find, "f", .command, menu: .edit, gate: .find),
        ShortcutEntry(.findNext, "g", .command, menu: .edit, gate: .find),
        ShortcutEntry(.findPrevious, "g", [.command, .shift], menu: .edit, gate: .find),
        ShortcutEntry(.useSelectionForFind, "e", .command, menu: .edit, gate: .find),
    ]

    private static let view: [ShortcutEntry] = [
        ShortcutEntry(.toggleCompactMode, "s", [.control, .command], menu: .view, gate: .toggleCompactMode),
        ShortcutEntry(.back, "[", .command, menu: .view, gate: .pageCommand),
        ShortcutEntry(.forward, "]", .command, menu: .view, gate: .pageCommand),
        ShortcutEntry(.reload, "r", .command, menu: .view, gate: .pageCommand),
        ShortcutEntry(.stop, ".", .command, menu: .view, gate: .pageCommand),
        ShortcutEntry(.actualSize, "0", .command, menu: .view, gate: .pageCommand),
        // Safari's menu shows ⌘+ and answers ⌘= too: on most layouts + needs Shift.
        ShortcutEntry(.zoomIn, "+", .command, menu: .view, gate: .pageCommand),
        ShortcutEntry(.zoomIn, "=", .command, menu: .view, gate: .pageCommand, isHidden: true),
        ShortcutEntry(.zoomOut, "-", .command, menu: .view, gate: .pageCommand),
        ShortcutEntry(.showDownloads, "l", [.option, .command], menu: .view, gate: .showDownloads),
    ]

    private static let historyAndDevelop: [ShortcutEntry] = [
        ShortcutEntry(.showAllHistory, "y", .command, menu: .history, gate: .showHistory),
        ShortcutEntry(.reopenClosedTab, "t", [.shift, .command], menu: .history, gate: .reopenClosedTab),
        ShortcutEntry(.showWebInspector, "i", [.option, .command], menu: .develop, gate: .pageCommand),
        ShortcutEntry(.showPageSource, "u", [.option, .command], menu: .develop, gate: .pageCommand),
    ]

    private static let tab: [ShortcutEntry] = [
        ShortcutEntry(.pinTab, "d", .command, menu: .tab, gate: .pinTab),
        ShortcutEntry(.nextTab, ShortcutKey.tab, .control, menu: .tab, gate: .selectTab),
        ShortcutEntry(.previousTab, ShortcutKey.tab, [.control, .shift], menu: .tab, gate: .selectTab),
        ShortcutEntry(.nextTab, "]", [.shift, .command], menu: .tab, gate: .selectTab, isHidden: true),
        ShortcutEntry(.previousTab, "[", [.shift, .command], menu: .tab, gate: .selectTab, isHidden: true),
        ShortcutEntry(.moveRowUp, ShortcutKey.upArrow, [.option, .command], menu: .tab, gate: .moveRow),
        ShortcutEntry(.moveRowDown, ShortcutKey.downArrow, [.option, .command], menu: .tab, gate: .moveRow),
    ] + (1...9).map { ShortcutEntry(.selectTab($0), String($0), .command, menu: .tab, gate: .selectTab, isHidden: true) }

    private static let workspaces: [ShortcutEntry] = (1...9).map {
        ShortcutEntry(.switchWorkspace($0), String($0), .control, menu: .workspaces, gate: .switchWorkspace)
    }

    /// Where Stave's meaning differs from Safari's on purpose, with Safari's meaning: ⌘D pins, standing in for Add Bookmark (question 18).
    public static let deliberateMappings: [ShortcutCommand: String] = [.pinTab: "Add Bookmark"]

    /// Keys macOS or the standard menus own, which the table never takes.
    public static let systemReserved: [(key: String, modifiers: ShortcutModifiers)] = [
        ("h", .command), ("h", [.option, .command]), ("m", .command), ("f", [.control, .command]),
        ("c", .command), ("v", .command), ("x", .command), ("a", .command), ("z", .command), ("z", [.shift, .command]),
    ]

    /// The entry a command's menu item shows; nil for a command with no key.
    public static func shown(_ command: ShortcutCommand) -> ShortcutEntry? {
        all.first { $0.command == command && !$0.isHidden }
    }

    /// The command a key runs, shown or alternate.
    public static func command(key: String, modifiers: ShortcutModifiers) -> ShortcutCommand? {
        all.first { $0.key == key && $0.modifiers == modifiers }?.command
    }

    /// The hidden entry a key press matches. `key` is the key as the ⌘ map reads it (`characters(byApplyingModifiers: .command)`, which is
    /// what AppKit's menus match on and which ignores Shift), so ⇧⌘] reads "]" and, on "Dvorak – QWERTY ⌘", ⌘] still reads "]".
    public static func hiddenEntry(key: String, modifiers: ShortcutModifiers) -> ShortcutEntry? {
        all.first { $0.isHidden && $0.key == key && $0.modifiers == modifiers }
    }
}

/// The titles of the menu items Task 10 adds. The other items keep their titles where they already live.
public enum ShortcutText {
    /// The one definition of "Pin Tab": the Tab menu's fixed item and the highlight's `SidebarAction.pin` both use it.
    public static let pinTabTitle = "Pin Tab"

    public static func title(_ command: ShortcutCommand) -> String {
        switch command {
        case .pinTab: pinTabTitle
        case .nextTab: "Show Next Tab"
        case .previousTab: "Show Previous Tab"
        case .reopenClosedTab: "Reopen Last Closed Tab"
        case .showDownloads: "Show Downloads"
        default: ""
        }
    }
}

/// Question 17's order rules, for any window's list of tabs in sidebar order.
public enum TabOrder {
    /// ⌘9 always selects the last tab.
    public static let lastTabNumber = 9

    /// ⌘1–⌘8 the nth tab, ⌘9 the last; nil past the end or outside 1–9.
    public static func tab(number: Int, in ids: [UUID]) -> UUID? {
        guard number >= 1, number <= lastTabNumber else { return nil }
        if number == lastTabNumber { return ids.last }
        return ids.indices.contains(number - 1) ? ids[number - 1] : nil
    }

    /// The tab `delta` places from `current`, wrapping at both ends as Safari does. With no current tab (or one not in the list), a step
    /// forward selects the first and a step back the last.
    public static func adjacent(to current: UUID?, by delta: Int, in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return delta < 0 ? ids.last : ids.first }
        let step = delta % ids.count // keeps a huge delta from overflowing
        return ids[((index + step) % ids.count + ids.count) % ids.count]
    }
}
