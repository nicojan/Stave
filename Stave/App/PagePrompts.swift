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
    /// Set for a sheet that comes from the waiting queue (media, sign-in, dialogs, external app), which goes back to waiting when its tab is hidden: marks it sent
    /// back (a flag, not a return code), then ends it.
    var sendBack: (() -> Void)?

    init(tabID: UUID, kind: PageQuestionKind? = nil, site: String? = nil, end: @escaping () -> Void, sendBack: (() -> Void)? = nil) {
        self.tabID = tabID
        self.kind = kind
        self.site = site
        self.end = end
        self.sendBack = sendBack
    }

    /// The kind of this sheet, for the kinds `PageQuestionQueues` cancels together (a camera, sign-in, dialog or external-app sheet from the
    /// waiting queue, a download question's sheet). Nil for the file picker, which a new document leaves alone.
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
/// can't be asked (another sheet is up, the window closed) or when `end` ends it. A page's dialog is a sheet on its own window, so it never
/// blocks another window.
///
/// Most questions are asked through the app-wide `PageQuestionCenter`, where they wait when they can't be shown, and are shown by whichever
/// window shows their tab when no sheet is up: camera and microphone, HTTP sign-in, several downloads, JavaScript dialogs (decision 21) and
/// the external-app question (decision 22). Hiding the tab while the sheet is up sends the question back to waiting. A camera question is
/// denied, remembering nothing, a sign-in question cancelled, a dialog answered with its safe answer and an external-app question dropped,
/// when the page goes away or navigates, its tab goes away (`forget`), or the window it is up on closes. The file picker and the
/// first-download question are asked only while the tab is shown, and are cancelled when it is hidden.
@MainActor
final class PagePrompts: PageQuestionWindow {
    private weak var window: NSWindow?
    private let pageHost: PageHost
    /// Whether this window shows the tab now: every question is asked only on the window showing its tab.
    private let shows: (UUID) -> Bool
    private var panels: [UUID: PagePanel] = [:]
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

    /// "Allow example.com to open this link in Zoom?", naming the frame that asks (a typed address names none), with the link below. Called
    /// by `PageQuestionQueues` when this window can ask now; `finish` hears how the sheet ended: answered (Open is true), sent back (its
    /// tab was hidden, so the question waits again) or cancelled (the page navigated or moved to another window, the window closed).
    func showExternalApp(tabID: UUID, host: String?, url: URL, appName: String, finish: @escaping (WaitingQuestions<Bool>.Result) -> Void) -> Bool {
        let alert = NSAlert()
        alert.messageText = PageText.externalAppQuestion(appName: appName, host: host)
        alert.informativeText = PageText.dialogMessage(url.absoluteString)
        alert.addButton(withTitle: PageText.openButton)
        alert.addButton(withTitle: PageText.cancelButton)
        return showQueued(alert, tabID: tabID, kind: .externalApp, finish: finish) { response, _ in
            response == .alertFirstButtonReturn || response == .alertSecondButtonReturn ? response == .alertFirstButtonReturn : nil
        }
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

    /// A JavaScript dialog: the asking frame's site as the heading and its capped text below. Called by `PageQuestionQueues` when this
    /// window can ask now; a tab hidden while it is up sends it back to waiting, keeping what was typed in a prompt.
    func showDialog(tabID: UUID, request: DialogRequest, finish: @escaping (WaitingQuestions<DialogReply>.Result) -> Void) -> Bool {
        let alert = NSAlert()
        alert.messageText = PageText.dialogHeading(origin: request.origin)
        alert.informativeText = PageText.dialogMessage(request.message)
        if request.offerToStop {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = PageText.stopDialogsOption
            alert.suppressionButton?.state = .off
        }
        var field: NSTextField?
        if case .prompt(let defaultText) = request.kind {
            let input = NSTextField(string: center.draft(for: tabID, request: request) ?? PageText.dialogMessage(defaultText ?? ""))
            input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            input.setAccessibilityLabel(PageText.dialogMessage(request.message))
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            field = input
        }
        alert.addButton(withTitle: PageText.okButton)
        if request.kind != .alert { alert.addButton(withTitle: PageText.cancelButton) }
        let shown = showQueued(alert, tabID: tabID, kind: .dialog, finish: { [center] (result: WaitingQuestions<DialogReply>.Result) in
            // What was typed survives a send back (the user hid the tab mid-answer), tied to this question; any other ending drops it.
            if case .sentBack = result { center.keepDraft(field?.stringValue, for: tabID, request: request) } else { center.keepDraft(nil, for: tabID, request: request) }
            finish(result)
        }, answer: { (response: NSApplication.ModalResponse, alert: NSAlert) -> DialogReply? in
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return nil }
            let accepted = response == .alertFirstButtonReturn
            return DialogReply(accepted: accepted, text: accepted ? field?.stringValue : nil, stopDialogs: alert.suppressionButton?.state == .on)
        })
        return shown
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

    /// Shows the alert as a sheet that belongs to the waiting queue: `answer` turns the user's button into the question's answer (nil for a
    /// sheet that was ended, not answered); a sheet ended because its tab was hidden reports `.sentBack`, any other ending `.cancelled`.
    /// False, with nothing shown, when this window can't ask now.
    private func showQueued<Answer: Sendable>(
        _ alert: NSAlert, tabID: UUID, kind: PageQuestionKind,
        finish: @escaping (WaitingQuestions<Answer>.Result) -> Void, answer: @escaping (NSApplication.ModalResponse, NSAlert) -> Answer?
    ) -> Bool {
        guard let window, canAsk(tabID) else { return false }
        let id = UUID()
        let sheet = alert.window
        let sentBack = SentBackFlag()
        panels[id] = PagePanel(
            tabID: tabID,
            kind: kind,
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
            if let answered = answer(response, alert) {
                finish(.answered(answered))
            } else {
                finish(sentBack.isSet ? .sentBack : .cancelled)
            }
            // The window is free of this sheet: another waiting question may go up.
            center.drain()
        }
        return true
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

    /// The tab is no longer shown here: its sheets come down. A camera, sign-in, several-files, dialog or external-app question goes back to waiting; every other one is cancelled.
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
        center.unregister(self)
        if let sheetEndObserver { NotificationCenter.default.removeObserver(sheetEndObserver) }
        sheetEndObserver = nil
    }

    /// A tab's page went away (closed, unloaded, reset): its dialog count goes with it, and its waiting questions (camera, sign-in, downloads,
    /// dialogs, the external-app question) are denied, cancelled or dropped.
    func forget(_ tabID: UUID) {
        center.cancel(tabID: tabID)
    }

    // MARK: - Internals

    func canAsk(_ tabID: UUID) -> Bool {
        guard let window, !isClosed, window.attachedSheet == nil else { return false }
        return shows(tabID)
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
