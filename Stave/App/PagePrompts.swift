import AppKit
import StaveCore
import StaveWeb

/// A page's question up as a sheet; `end` cancels it, and its waiting question then resolves with the safe answer.
struct PagePanel {
    let tabID: UUID
    let end: () -> Void
    /// Set for a sheet whose question waits again when its tab is hidden (the media question): takes the sheet down without resolving it.
    var sendBack: (() -> Void)?

    init(tabID: UUID, end: @escaping () -> Void, sendBack: (() -> Void)? = nil) {
        self.tabID = tabID
        self.end = end
        self.sendBack = sendBack
    }
}

/// The user's answer to the camera and microphone question.
struct MediaAnswer: Sendable {
    let allow: Bool
    let remember: Bool
}

/// The sheets one window (a browser window or a pop-up) shows for its pages: the external-app question, "download several files", camera
/// and microphone, JavaScript alert, confirm and prompt, and the file picker. Every question resolves exactly once: answered, or refused, denied or cancelled when it
/// can't be asked (its tab isn't shown here, another sheet is up, the window closed) or when `end` ends it. A page's dialog is a sheet on its
/// own window, so it never blocks another window.
///
/// The camera and microphone question is the exception to "refused at once": when it can't be shown it waits (`WaitingQuestions`) and is shown
/// when its tab is shown and no sheet is up. Hiding its tab while the sheet is up sends it back to waiting. It is denied, remembering nothing,
/// when its tab goes away (`forget`) or the window closes.
@MainActor
final class PagePrompts {
    private weak var window: NSWindow?
    private let pageHost: PageHost
    /// Whether this window shows the tab now: every question is asked only on the window showing its tab.
    private let shows: (UUID) -> Bool
    private var panels: [UUID: PagePanel] = [:]
    /// Per tab: stops a page that loops `alert()` from locking the window (`PageDialogGate`). Each gate belongs to one `LivePage` (held
    /// weakly): a page that was unloaded or remade gets a fresh gate, so a stopped gate never matches the new page's commit count.
    private var gates: [UUID: GateEntry] = [:]

    private struct GateEntry {
        weak var page: LivePage?
        var gate: PageDialogGate
    }
    private var isClosed = false
    private let mediaQuestions = WaitingQuestions<MediaAnswer>()
    private var sheetEndObserver: NSObjectProtocol?

    init(window: NSWindow, pageHost: PageHost, shows: @escaping (UUID) -> Bool) {
        self.window = window
        self.pageHost = pageHost
        self.shows = shows
        // Any sheet ending on the window (a page's or the app's own) may free a waiting question.
        sheetEndObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mayAskAgain() }
        }
    }


    // MARK: - Questions

    /// "Allow example.com to open this link in Zoom?", naming the page that asks (a typed address names none), with the link below.
    func confirmExternalApp(tabID: UUID, host: String?, url: URL, appName: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = PageText.externalAppQuestion(appName: appName, host: host)
        alert.informativeText = PageText.dialogMessage(url.absoluteString)
        alert.addButton(withTitle: PageText.openButton)
        alert.addButton(withTitle: PageText.cancelButton)
        return await present(alert, for: tabID) == .alertFirstButtonReturn
    }

    /// "example.com wants to download a file", Allow / Don't Allow, for the first download of a page Stave reopened by itself. A cancelled
    /// sheet refuses.
    func confirmDownload(tabID: UUID, host: String?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = PageText.downloadQuestion(host: host)
        alert.informativeText = PageText.downloadDetail
        alert.addButton(withTitle: PageText.allowButton)
        alert.addButton(withTitle: PageText.dontAllowButton)
        return await present(alert, for: tabID) == .alertFirstButtonReturn
    }

    /// "example.com wants to download several files", Allow / Don't Allow. A cancelled sheet refuses.
    func confirmSeveralDownloads(tabID: UUID, host: String?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = PageText.severalDownloadsQuestion(host: host)
        alert.informativeText = PageText.severalDownloadsDetail
        alert.addButton(withTitle: PageText.allowButton)
        alert.addButton(withTitle: PageText.dontAllowButton)
        return await present(alert, for: tabID) == .alertFirstButtonReturn
    }

    /// "Allow example.com to use your camera?" with Allow / Don't Allow and "Remember for this site", ticked by default (decision 11). Only an
    /// Allow is remembered (`mediaDecision` stores nothing for a Don't Allow). A question that can't be shown yet waits (see the type's note);
    /// one that is cancelled denies and remembers nothing.
    func askMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool) async -> (allow: Bool, remember: Bool) {
        let answer = await mediaQuestions.ask(tabID: tabID) { [weak self] finish in
            self?.showMedia(tabID: tabID, host: host, camera: camera, microphone: microphone, finish: finish) ?? false
        }
        return (answer?.allow ?? false, answer?.remember ?? false)
    }

    /// Shows the media sheet if it can be asked now. `finish` hears how it ended: answered, sent back (its tab was hidden), or cancelled.
    private func showMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool, finish: @escaping (WaitingQuestions<MediaAnswer>.Result) -> Void) -> Bool {
        guard let window, canAsk(tabID) else { return false }
        let alert = NSAlert()
        alert.messageText = PageText.mediaQuestion(host: host, camera: camera, microphone: microphone)
        alert.addButton(withTitle: PageText.allowButton)
        alert.addButton(withTitle: PageText.dontAllowButton)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = PageText.rememberForSite
        alert.suppressionButton?.state = .on
        let id = UUID()
        let sheet = alert.window
        panels[id] = PagePanel(
            tabID: tabID,
            end: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                window.endSheet(sheet, returnCode: .abort)
            },
            // `.cancel` is a code no button of the alert returns, so it can only mean "sent back".
            sendBack: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                window.endSheet(sheet, returnCode: .cancel)
            }
        )
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.panels[id] = nil
            switch response {
            case .alertFirstButtonReturn, .alertSecondButtonReturn:
                finish(.answered(MediaAnswer(allow: response == .alertFirstButtonReturn, remember: alert.suppressionButton?.state == .on)))
            case .cancel: finish(.sentBack)
            default: finish(.cancelled)
            }
        }
        return true
    }

    func alert(tabID: UUID, origin: String?, message: String) async {
        guard let alert = dialog(tabID: tabID, origin: origin, message: message) else { return }
        alert.addButton(withTitle: PageText.okButton)
        _ = await presentDialog(alert, tabID: tabID)
    }

    func confirm(tabID: UUID, origin: String?, message: String) async -> Bool {
        guard let alert = dialog(tabID: tabID, origin: origin, message: message) else { return false }
        alert.addButton(withTitle: PageText.okButton)
        alert.addButton(withTitle: PageText.cancelButton)
        return await presentDialog(alert, tabID: tabID) == .alertFirstButtonReturn
    }

    func prompt(tabID: UUID, origin: String?, message: String, defaultText: String?) async -> String? {
        guard let alert = dialog(tabID: tabID, origin: origin, message: message) else { return nil }
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

    /// The tab is no longer shown here: its sheets come down. A media question goes back to waiting; every other one is cancelled.
    func hide(_ tabID: UUID) {
        for (id, panel) in panels where panel.tabID == tabID {
            panels[id] = nil
            (panel.sendBack ?? panel.end)()
        }
    }

    /// Something that could have blocked a waiting question changed (a tab is shown, a sheet ended): shows the ones that can be shown now.
    /// Hops a turn, so a sheet that is still coming down is gone when the check runs.
    func mayAskAgain() {
        Task { @MainActor [weak self] in self?.mediaQuestions.drain() }
    }

    /// The window is closing: every sheet ends and later questions resolve at once.
    func close() {
        end { _ in true }
        isClosed = true
        gates = [:]
        mediaQuestions.close()
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheetEndObserver = nil
    }

    /// A tab's page went away (closed, unloaded, reset): its dialog count goes with it, and its waiting media question is denied.
    func forget(_ tabID: UUID) {
        gates[tabID] = nil
        mediaQuestions.cancel(tabID: tabID)
    }

    // MARK: - Internals

    private func canAsk(_ tabID: UUID) -> Bool {
        guard let window, !isClosed, window.attachedSheet == nil else { return false }
        return shows(tabID)
    }

    /// The JavaScript dialog: the asking frame's site as the heading and its capped text below. Nil when the page's dialogs were stopped,
    /// or the page is gone, so the question resolves at once.
    private func dialog(tabID: UUID, origin: String?, message: String) -> NSAlert? {
        guard let page = pageHost.existingPage(tabID) else { return nil }
        var entry = gates[tabID].flatMap { $0.page === page ? $0 : nil } ?? GateEntry(page: page, gate: PageDialogGate())
        let verdict = entry.gate.next(at: Date(), navigation: page.commitCount)
        gates[tabID] = entry
        guard case .ask(let offerToStop) = verdict else { return nil }
        let alert = NSAlert()
        alert.messageText = PageText.dialogHeading(origin: origin)
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
        let page = pageHost.existingPage(tabID)
        let navigation = page?.commitCount ?? 0
        let response = await present(alert, for: tabID)
        // Only the page that asked is stopped; a page remade while the sheet was up keeps its own fresh gate.
        if alert.showsSuppressionButton, alert.suppressionButton?.state == .on, var entry = gates[tabID], let page, entry.page === page {
            entry.gate.stop(navigation: navigation)
            gates[tabID] = entry
        }
        return response
    }

    /// Shows the alert as a sheet and waits for its answer, or `.abort` at once when it can't be asked.
    private func present(_ alert: NSAlert, for tabID: UUID) async -> NSApplication.ModalResponse {
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
