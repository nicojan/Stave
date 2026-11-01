import AppKit
import StaveCore
import StaveWeb

/// A page's question up as a sheet; `end` cancels it, and its waiting question then resolves with the safe answer.
struct PagePanel {
    let tabID: UUID?
    let end: () -> Void
}

/// The sheets one window (a browser window or a pop-up) shows for its pages: the external-app question, camera and microphone, JavaScript
/// alert, confirm and prompt, and the file picker. Every question resolves exactly once: answered, or refused, denied or cancelled when it
/// can't be asked (its tab isn't shown here, another sheet is up, the window closed) or when `end` ends it. A page's dialog is a sheet on its
/// own window, so it never blocks another window.
@MainActor
final class PagePrompts {
    private weak var window: NSWindow?
    private let pageHost: PageHost
    /// Whether this window shows the tab now; a nil tab (the external-app question) is always allowed.
    private let shows: (UUID) -> Bool
    private var panels: [UUID: PagePanel] = [:]
    /// Per page: stops a page that loops `alert()` from locking the window (`PageDialogGate`).
    private var gates: [UUID: PageDialogGate] = [:]
    private var isClosed = false

    init(window: NSWindow, pageHost: PageHost, shows: @escaping (UUID) -> Bool) {
        self.window = window
        self.pageHost = pageHost
        self.shows = shows
    }

    // MARK: - Questions

    func confirmExternalApp(url: URL, appName: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = PageText.externalAppQuestion(appName: appName)
        alert.informativeText = PageText.dialogMessage(url.absoluteString)
        alert.addButton(withTitle: PageText.openButton)
        alert.addButton(withTitle: PageText.cancelButton)
        return await present(alert, for: nil) == .alertFirstButtonReturn
    }

    /// "Allow example.com to use your camera?" with Allow / Don't Allow and "Remember for this site". A cancelled sheet denies and remembers
    /// nothing.
    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        let alert = NSAlert()
        alert.messageText = PageText.mediaQuestion(host: host, camera: camera, microphone: microphone)
        alert.addButton(withTitle: PageText.allowButton)
        alert.addButton(withTitle: PageText.dontAllowButton)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = PageText.rememberForSite
        alert.suppressionButton?.state = .off
        let response = await present(alert, for: tabID)
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return (false, false) }
        return (response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
    }

    func alert(tabID: UUID, message: String) async {
        guard let alert = dialog(tabID: tabID, message: message) else { return }
        alert.addButton(withTitle: PageText.okButton)
        _ = await presentDialog(alert, tabID: tabID)
    }

    func confirm(tabID: UUID, message: String) async -> Bool {
        guard let alert = dialog(tabID: tabID, message: message) else { return false }
        alert.addButton(withTitle: PageText.okButton)
        alert.addButton(withTitle: PageText.cancelButton)
        return await presentDialog(alert, tabID: tabID) == .alertFirstButtonReturn
    }

    func prompt(tabID: UUID, message: String, defaultText: String?) async -> String? {
        guard let alert = dialog(tabID: tabID, message: message) else { return nil }
        let field = NSTextField(string: PageText.dialogMessage(defaultText ?? ""))
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel(PageText.dialogMessage(message))
        alert.accessoryView = field
        alert.addButton(withTitle: PageText.okButton)
        alert.addButton(withTitle: PageText.cancelButton)
        alert.window.initialFirstResponder = field
        return await presentDialog(alert, tabID: tabID) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// The upload picker, as a sheet. Cancelled (nil) when it can't be shown or is ended.
    func chooseFiles(tabID: UUID, allowsMultiple: Bool, allowsDirectories: Bool) async -> [URL]? {
        guard let window, canAsk(tabID) else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = allowsDirectories
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        let id = UUID()
        panels[id] = PagePanel(tabID: tabID, end: { [weak panel] in panel?.cancel(nil) })
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        panels[id] = nil
        return response == .OK ? panel.urls : nil
    }

    // MARK: - Ending

    /// Ends the matching sheets as cancelled; each one's waiting question then resolves.
    func end(where matches: (PagePanel) -> Bool) {
        for (id, panel) in panels where matches(panel) {
            panels[id] = nil
            panel.end()
        }
    }

    /// The window is closing: every sheet ends and later questions resolve at once.
    func close() {
        end { _ in true }
        isClosed = true
        gates = [:]
    }

    /// A tab's page went away (closed, unloaded, reset): its dialog count goes with it.
    func forget(_ tabID: UUID) {
        gates[tabID] = nil
    }

    // MARK: - Internals

    private func canAsk(_ tabID: UUID?) -> Bool {
        guard let window, !isClosed, window.attachedSheet == nil else { return false }
        if let tabID { return shows(tabID) }
        return true
    }

    /// The JavaScript dialog: the page's site as the heading and its capped text below. Nil when the page's dialogs were stopped, so the
    /// question resolves at once.
    private func dialog(tabID: UUID, message: String) -> NSAlert? {
        let page = pageHost.existingPage(tabID)
        var gate = gates[tabID] ?? PageDialogGate()
        let verdict = gate.next(at: Date(), navigation: page?.commitCount ?? 0)
        gates[tabID] = gate
        guard case .ask(let offerToStop) = verdict else { return nil }
        let alert = NSAlert()
        alert.messageText = PageText.dialogHeading(pageURL: page?.status.url ?? "")
        alert.informativeText = PageText.dialogMessage(message)
        if offerToStop {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = PageText.stopDialogsOption
            alert.suppressionButton?.state = .off
        }
        return alert
    }

    /// Shows a JavaScript dialog; a ticked "Don't show more dialogs" stops the page's dialogs until it navigates.
    private func presentDialog(_ alert: NSAlert, tabID: UUID) async -> NSApplication.ModalResponse {
        let navigation = pageHost.existingPage(tabID)?.commitCount ?? 0
        let response = await present(alert, for: tabID)
        if alert.showsSuppressionButton, alert.suppressionButton?.state == .on, var gate = gates[tabID] {
            gate.stop(navigation: navigation)
            gates[tabID] = gate
        }
        return response
    }

    /// Shows the alert as a sheet and waits for its answer, or `.abort` at once when it can't be asked.
    private func present(_ alert: NSAlert, for tabID: UUID?) async -> NSApplication.ModalResponse {
        guard let window, canAsk(tabID) else { return .abort }
        let id = UUID()
        let sheet = alert.window
        panels[id] = PagePanel(tabID: tabID, end: { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet, returnCode: .abort)
        })
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        panels[id] = nil
        return response
    }
}
