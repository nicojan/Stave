import AppKit
import StaveCore

/// The two alerts Settings shows: the question before something is deleted, and a plain refusal. Their words come from `DeletionCopy` and
/// `SettingsCopy`.
@MainActor
enum SettingsAlerts {
    /// The question alert. Cancel is the default button (Return, and the highlighted one); Delete is the destructive one, never the default.
    /// AppKit gives a first button titled "Cancel" only Escape and no Return, so Return is set by hand, and Escape is then answered by
    /// `confirmDestructive` (a button has one key equivalent).
    static func makeDestructiveAlert(_ question: String, destructiveTitle: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question
        let cancel = alert.addButton(withTitle: DeletionCopy.cancelButton)
        alert.addButton(withTitle: destructiveTitle).hasDestructiveAction = true
        cancel.keyEquivalent = "\r"
        return alert
    }

    /// Asks before a deletion. Return and Escape both cancel; only the Delete button (by click or Tab and Space) deletes.
    static func confirmDestructive(_ question: String, destructiveTitle: String = DeletionCopy.deleteButton) async -> Bool {
        let alert = makeDestructiveAlert(question, destructiveTitle: destructiveTitle)
        let cancel = alert.buttons[0]
        let escape = EscapeCancel(alert: alert, cancel: cancel)
        defer { escape.stop() }
        if let window = NSApp.keyWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertSecondButtonReturn) }
            }
        }
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Says why something can't be done, with one OK button.
    static func inform(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = text
        alert.addButton(withTitle: SettingsCopy.okButton)
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Escape presses Cancel while the alert is up, since Cancel's one key equivalent is Return. Lives only as long as the alert.
@MainActor
private final class EscapeCancel {
    private var monitor: Any?

    init(alert: NSAlert, cancel: NSButton) {
        let escapeKeyCode: UInt16 = 53
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert, weak cancel] event in
            guard event.keyCode == escapeKeyCode, let alert, event.window === alert.window else { return event }
            cancel?.performClick(nil)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
