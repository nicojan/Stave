import AppKit
import SwiftUI
import StaveCore

/// Maps `StandardShortcuts` onto SwiftUI and AppKit. The menus attach keys only through `standardShortcut(_:)`, so the table stays the one
/// place a key is assigned (decision 16).
enum StandardShortcutKeys {
    static func keyEquivalent(_ key: String) -> KeyEquivalent? {
        switch key {
        case ShortcutKey.upArrow: .upArrow
        case ShortcutKey.downArrow: .downArrow
        case ShortcutKey.tab: .tab
        default: key.first.map { KeyEquivalent($0) }
        }
    }

    static func eventModifiers(_ modifiers: ShortcutModifiers) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// The modifiers of a key press, as the table writes them.
    static func modifiers(of event: NSEvent) -> ShortcutModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var result: ShortcutModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    /// The hidden entry a key press matches. The key is read with the ⌘ map, as AppKit's menus do, so "Dvorak – QWERTY ⌘" reads ⌘] as "]"
    /// (not Dvorak's key); that read also ignores Shift, so ⇧⌘] reads "]". Falls back to the unmodified read when AppKit has no ⌘ reading.
    static func hiddenEntry(for event: NSEvent) -> ShortcutEntry? {
        guard let key = event.characters(byApplyingModifiers: .command) ?? event.charactersIgnoringModifiers else { return nil }
        return StandardShortcuts.hiddenEntry(key: key, modifiers: modifiers(of: event))
    }
}

extension View {
    /// The command's shown key from `StandardShortcuts`, and its declared gate as the real guard: the item is disabled while the gate is
    /// closed (a sheet is up), ANDed with the item's own `enabled` condition. A command with no entry gets no key; one with no gate (Quit,
    /// Settings) is never gated.
    @ViewBuilder
    func standardShortcut(_ command: ShortcutCommand, state: AppMenuState, enabled: Bool = true) -> some View {
        let entry = StandardShortcuts.shown(command)
        let allowed = enabled && (entry?.isEnabled(busy: state.isBusy) ?? true)
        if let entry, let key = StandardShortcutKeys.keyEquivalent(entry.key) {
            keyboardShortcut(key, modifiers: StandardShortcutKeys.eventModifiers(entry.modifiers)).disabled(!allowed)
        } else {
            disabled(!allowed)
        }
    }
}
