import AppKit
import StaveCore
import SwiftUI
import StaveWeb

/// A page's question up as a sheet; `end` cancels it, and its waiting question then resolves with the safe answer.
struct PagePanel {
    let tabID: UUID
    let end: () -> Void
    /// For a sign-in sheet: the site it is about (`AuthChallenge.siteKey`), so a failed load can end only that site's sheet.
    var site: String?
    /// Set for a sheet that comes from the waiting queue (media, sign-in), which goes back to waiting when its tab is hidden: marks it sent
    /// back (a flag, not a return code), then ends it.
    var sendBack: (() -> Void)?

    init(tabID: UUID, kind: PageQuestionKind? = nil, site: String? = nil, end: @escaping () -> Void, sendBack: (() -> Void)? = nil) {
        self.tabID = tabID
        self.kind = kind
        self.site = site
        self.end = end
        self.sendBack = sendBack
    }

    /// The kind of question this sheet is, for the kinds `PageQuestionQueues` cancels together (a camera or sign-in sheet from the waiting
    /// queue, a download question's sheet). Nil for the rest (JavaScript dialogs, the file picker, the external-app question), which a new
    /// document leaves alone.
    var kind: PageQuestionKind?

    var isQueued: Bool { sendBack != nil }
}

/// A weak reference to one sheet, for a callback made before the sheet exists.
@MainActor
final class SheetReference {
    weak var sheet: NSWindow?
}

/// Set when a camera or sign-in sheet is taken down because its tab was hidden, before the sheet ends: its completion then reports "sent back" rather
/// than "cancelled". A flag, because a return code could be mistaken for another way a sheet ends (`AppDelegate.quit()` ends sheets with `.cancel`).
@MainActor
final class SentBackFlag {
    var isSet = false
}

/// The sheets one window (a browser window or a pop-up) shows for its pages: the external-app question, "download a file", "download
/// several files", camera and microphone, HTTP sign-in, JavaScript alert, confirm and prompt, and the file picker. Every question resolves exactly once: answered, or refused, denied or cancelled when it
/// can't be asked (its tab isn't shown here, another sheet is up, the window closed) or when `end` ends it. A page's dialog is a sheet on its
/// own window, so it never blocks another window.
///
/// The camera and microphone, HTTP sign-in and several-downloads questions are the exception to "refused at once": they are asked through the
/// app-wide `PageQuestionCenter`, where they wait when they can't be shown, and are shown by whichever window shows their tab when no sheet
/// is up. Hiding the tab while the sheet is up sends the question back to waiting. A camera question is denied, remembering nothing, and a
/// sign-in question cancelled, when the page goes away or navigates, its tab goes away (`forget`), or the window it is up on closes.
@MainActor
final class PagePrompts: PageQuestionWindow {
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
    private let center: PageQuestionCenter
    private var sheetEndObserver: NSObjectProtocol?

    init(window: NSWindow, pageHost: PageHost, center: PageQuestionCenter, shows: @escaping (UUID) -> Bool) {
        self.window = window
        self.pageHost = pageHost
        self.center = center
        self.shows = shows
        center.register(self)
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

    /// "example.com wants to download a file", Allow / Don't Allow, for the first download of a page Stave reopened by itself. Only a real
    /// Don't Allow is `declined`; a sheet that can't be shown or comes down is `unasked`.
    func confirmDownload(tabID: UUID, host: String?) async -> QuestionAnswer {
        let alert = NSAlert()
        alert.messageText = PageText.downloadQuestion(host: host)
        alert.informativeText = PageText.downloadDetail
        alert.addButton(withTitle: PageText.allowButton)
        alert.addButton(withTitle: PageText.dontAllowButton)
        return Self.downloadAnswer(await present(alert, for: tabID, isDownload: true))
    }

    /// "example.com wants to download several files", Allow / Don't Allow. Called by `PageQuestionQueues` when this window can ask now;
    /// `finish` hears how the sheet ended: answered, sent back (its tab was hidden, so the question waits again) or cancelled (the page
    /// navigated or went away, the window closed). Held, not refused, while it can't be shown (decision 29).
    func showSeveralDownloads(tabID: UUID, host: String?, finish: @escaping (WaitingQuestions<DownloadChoice>.Result) -> Void) -> Bool {
        guard let window, canAsk(tabID) else { return false }
        let alert = NSAlert()
        alert.messageText = PageText.severalDownloadsQuestion(host: host)
        alert.informativeText = PageText.severalDownloadsDetail
        alert.addButton(withTitle: PageText.allowButton)
        alert.addButton(withTitle: PageText.dontAllowButton)
        let id = UUID()
        let sheet = alert.window
        let sentBack = SentBackFlag()
        panels[id] = PagePanel(
            tabID: tabID,
            kind: .download,
            end: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                window.endSheet(sheet, returnCode: .abort)
            },
            sendBack: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                sentBack.isSet = true
                window.endSheet(sheet, returnCode: .abort)
            }
        )
        let center = center
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.panels[id] = nil
            switch response {
            case .alertFirstButtonReturn: finish(.answered(.allow))
            case .alertSecondButtonReturn: finish(.answered(.dontAllow))
            default: finish(sentBack.isSet ? .sentBack : .cancelled)
            }
            // The window is free of this sheet: another waiting question may go up.
            center.drain()
        }
        return true
    }

    private static func downloadAnswer(_ response: NSApplication.ModalResponse) -> QuestionAnswer {
        switch response {
        case .alertFirstButtonReturn: .allowed
        case .alertSecondButtonReturn: .declined
        default: .unasked
        }
    }

    /// "Allow example.com to use your camera?" with Allow / Don't Allow and "Remember for this site", ticked by default (decision 11). With the box
    /// ticked, an Allow is stored as Allow and a Don't Allow as Block (decision 32, `mediaDecision`). Called by `PageQuestionQueues` when this window can ask now;
    /// `finish` hears how the sheet ended: answered, sent back (its tab was hidden), or cancelled.
    func showMedia(tabID: UUID, host: String, camera: Bool, microphone: Bool, finish: @escaping (WaitingQuestions<MediaAnswer>.Result) -> Void) -> Bool {
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
        let sentBack = SentBackFlag()
        panels[id] = PagePanel(
            tabID: tabID,
            kind: .media,
            end: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                window.endSheet(sheet, returnCode: .abort)
            },
            sendBack: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                sentBack.isSet = true
                window.endSheet(sheet, returnCode: .abort)
            }
        )
        let center = center
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.panels[id] = nil
            switch response {
            case .alertFirstButtonReturn, .alertSecondButtonReturn:
                finish(.answered(MediaAnswer(allow: response == .alertFirstButtonReturn, remember: alert.suppressionButton?.state == .on)))
            default:
                finish(sentBack.isSet ? .sentBack : .cancelled)
            }
            // The window is free of this sheet: another waiting question may go up. A backup to the sheet-end notification.
            center.drain()
        }
        return true
    }

    /// The HTTP sign-in sheet (`AuthSheet`). Called by `PageQuestionQueues` when this window can ask now; `finish` hears how it ended: signed
    /// in, cancelled by the user, sent back (its tab was hidden) or cancelled (the page went away). Stave keeps no password: the answer is
    /// handed to WebKit and forgotten.
    func showAuth(tabID: UUID, challenge: AuthChallenge, finish: @escaping (WaitingQuestions<AuthReply>.Result) -> Void) -> Bool {
        guard let window, canAsk(tabID) else { return false }
        let result = AuthSheetResult()
        // The sheet this callback belongs to, not whichever sheet is attached to the window now (a sheet of another kind may have replaced
        // it). The first call decides; a second (a double click, Return then Cancel) is ignored.
        let own = SheetReference()
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: AuthSheet(challenge: challenge, onFinish: { [weak window, own] answer in
            guard !result.isUserChoice else { return }
            result.answer = answer
            result.isUserChoice = true
            if let window, let sheet = own.sheet { window.endSheet(sheet) }
        })))
        own.sheet = sheet
        let id = UUID()
        let sentBack = SentBackFlag()
        panels[id] = PagePanel(
            tabID: tabID,
            kind: .auth,
            site: challenge.siteKey,
            end: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                window.endSheet(sheet, returnCode: .abort)
            },
            sendBack: { [weak window, weak sheet] in
                guard let window, let sheet else { return }
                sentBack.isSet = true
                window.endSheet(sheet, returnCode: .abort)
            }
        )
        let center = center
        window.beginSheet(sheet) { [weak self] _ in
            self?.panels[id] = nil
            if result.isUserChoice {
                // Sign In answers; the user's Cancel is a reply (`.cancelled`) that counts toward the cancel limit. The delegate sends no
                // credential for either.
                finish(.answered(result.answer.map { .signedIn($0) } ?? .cancelled))
            } else {
                // Taken down by the system (page gone, failed load, window closed): no reply, so it never counts as the user's Cancel.
                finish(sentBack.isSet ? .sentBack : .cancelled)
            }
            center.drain()
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

    /// Ends the tab's sheets of these kinds as cancelled; each one's waiting question then resolves (`PageQuestionWindow`).
    func endSheets(tabID: UUID, kinds: Set<PageQuestionKind>) {
        end { $0.tabID == tabID && $0.kind.map(kinds.contains) == true }
    }

    /// Ends the tab's sign-in sheet about `site` only, as cancelled by the system.
    func endAuthSheets(tabID: UUID, site: String) {
        end { $0.tabID == tabID && $0.kind == .auth && $0.site == site }
    }

    /// Ends the matching sheets as cancelled; each one's waiting question then resolves.
    func end(where matches: (PagePanel) -> Bool) {
        for (id, panel) in panels where matches(panel) {
            panels[id] = nil
            panel.end()
        }
    }

    /// The tab is no longer shown here: its sheets come down. A camera, sign-in or several-files question goes back to waiting; every other one is cancelled.
    func hide(_ tabID: UUID) {
        for (id, panel) in panels where panel.tabID == tabID {
            panels[id] = nil
            (panel.sendBack ?? panel.end)()
        }
    }

    /// Something that could have blocked a waiting question changed (a tab is shown, a sheet ended): shows the ones that can be shown now.
    /// Hops a turn, so a sheet that is still coming down is gone when the check runs.
    func mayAskAgain() {
        center.drain()
    }

    /// The window is closing: every sheet ends and later questions resolve at once.
    func close() {
        end { _ in true }
        isClosed = true
        gates = [:]
        center.unregister(self)
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheetEndObserver = nil
    }

    /// A tab's page went away (closed, unloaded, reset): its dialog count goes with it, and its waiting camera and sign-in questions are denied or cancelled.
    func forget(_ tabID: UUID) {
        gates[tabID] = nil
        center.cancel(tabID: tabID)
    }

    // MARK: - Internals

    func canAsk(_ tabID: UUID) -> Bool {
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
    private func present(_ alert: NSAlert, for tabID: UUID, isDownload: Bool = false) async -> NSApplication.ModalResponse {
        guard let window, canAsk(tabID) else { return .abort }
        let id = UUID()
        let sheet = alert.window
        var panel = PagePanel(tabID: tabID, end: { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet, returnCode: .abort)
        })
        panel.kind = isDownload ? .download : nil
        panels[id] = panel
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        panels[id] = nil
        return response
    }
}
