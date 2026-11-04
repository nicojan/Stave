import Foundation
import Testing
@testable import StaveCore

struct PageDialogTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func firstTwoDialogsAskPlainly() {
        var gate = PageDialogGate()
        #expect(gate.next(at: start, navigation: 1) == .ask(offerToStop: false))
        #expect(gate.next(at: start.addingTimeInterval(1), navigation: 1) == .ask(offerToStop: false))
    }

    @Test func thirdDialogInAShortWindowOffersToStop() {
        var gate = PageDialogGate()
        _ = gate.next(at: start, navigation: 1)
        _ = gate.next(at: start.addingTimeInterval(1), navigation: 1)
        #expect(gate.next(at: start.addingTimeInterval(2), navigation: 1) == .ask(offerToStop: true))
        #expect(gate.next(at: start.addingTimeInterval(3), navigation: 1) == .ask(offerToStop: true))
    }

    @Test func spacedOutDialogsNeverOffer() {
        var gate = PageDialogGate()
        for step in 0..<6 {
            let at = start.addingTimeInterval(Double(step) * (PageDialogGate.window + 1))
            #expect(gate.next(at: at, navigation: 1) == .ask(offerToStop: false))
        }
    }

    @Test func stoppedPageResolvesAtOnceUntilItNavigates() {
        var gate = PageDialogGate()
        for step in 0..<3 { _ = gate.next(at: start.addingTimeInterval(Double(step)), navigation: 4) }
        gate.stop(navigation: 4)
        #expect(gate.next(at: start.addingTimeInterval(4), navigation: 4) == .resolveAtOnce)
        #expect(gate.next(at: start.addingTimeInterval(500), navigation: 4) == .resolveAtOnce)
        // A new document starts afresh, with no count carried over.
        #expect(gate.next(at: start.addingTimeInterval(501), navigation: 5) == .ask(offerToStop: false))
        #expect(gate.next(at: start.addingTimeInterval(502), navigation: 5) == .ask(offerToStop: false))
    }

    @Test func navigationResetsTheCount() {
        var gate = PageDialogGate()
        _ = gate.next(at: start, navigation: 1)
        _ = gate.next(at: start.addingTimeInterval(1), navigation: 1)
        #expect(gate.next(at: start.addingTimeInterval(2), navigation: 2) == .ask(offerToStop: false))
    }

    @Test func messageIsCappedWithAnEllipsis() {
        let long = String(repeating: "a", count: 5_000)
        let shown = PageText.dialogMessage(long)
        #expect(shown.count == PageText.dialogMessageLimit + 1)
        #expect(shown.hasSuffix("…"))
        #expect(PageText.dialogMessage("Hello") == "Hello")
        #expect(PageText.dialogMessage(String(repeating: "b", count: PageText.dialogMessageLimit)).count == PageText.dialogMessageLimit)
    }

    @Test func headingNamesTheOrigin() {
        #expect(PageText.dialogHeading(origin: "https://www.example.com:8443/path") == "example.com says")
        #expect(PageText.dialogHeading(origin: "ads.example.net") == "ads.example.net says")
        #expect(PageText.dialogHeading(origin: "") == "This page says")
        #expect(PageText.dialogHeading(origin: nil) == "This page says")
        #expect(PageText.dialogHeading(origin: "about:blank") == "This page says")
        #expect(PageText.stopDialogsOption == "Don’t show more dialogs from this page")
    }

    @Test func popupFrameDefaultsAndClamps() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(PopupFrame.size(width: nil, height: nil, visibleFrame: screen) == CGSize(width: 480, height: 640))
        #expect(PopupFrame.size(width: 500, height: nil, visibleFrame: screen) == CGSize(width: 500, height: 640))
        #expect(PopupFrame.size(width: 5_000, height: 3_000, visibleFrame: screen) == CGSize(width: 1440, height: 900))
        #expect(PopupFrame.size(width: 10, height: 10, visibleFrame: screen) == CGSize(width: PopupFrame.minimum.width, height: PopupFrame.minimum.height))
    }

    /// A pop-up's title always leads with the site it shows, so a page can't pass its window off as another site's.
    @Test func popupTitleLeadsWithTheHost() {
        #expect(PopupFrame.title(pageTitle: "Sign in", url: "https://accounts.example.com/x") == "accounts.example.com — Sign in")
        #expect(PopupFrame.title(pageTitle: "  ", url: "https://accounts.example.com/x") == "accounts.example.com")
        #expect(PopupFrame.title(pageTitle: "", url: "https://www.Example.com:8443/") == "example.com")
        // A title claiming another site still comes after the real host.
        #expect(PopupFrame.title(pageTitle: "bank.example — Log in", url: "https://evil.example.net/") == "evil.example.net — bank.example — Log in")
        // An opaque origin (blank, data:, nothing loaded yet) gets the neutral word first.
        #expect(PopupFrame.title(pageTitle: "", url: "") == "Pop-up")
        #expect(PopupFrame.title(pageTitle: "Hi", url: "about:blank") == "Pop-up — Hi")
        #expect(PopupFrame.title(pageTitle: "x", url: "data:text/html,x") == "Pop-up — x")
        // The page's title is capped, then an ellipsis; whitespace runs are folded.
        let long = String(repeating: "t", count: 500)
        let capped = PopupFrame.title(pageTitle: long, url: "https://a.example/")
        #expect(capped == "a.example — " + String(repeating: "t", count: PopupFrame.titleLimit) + "…")
        #expect(PopupFrame.title(pageTitle: "a\n\tb", url: "https://a.example/") == "a.example — a b")
    }

    @Test func externalAppQuestionNamesTheAskingSite() {
        #expect(PageText.externalAppQuestion(appName: "Zoom", host: "https://www.example.com/meet") == "Allow example.com to open this link in Zoom?")
        #expect(PageText.externalAppQuestion(appName: "Mail", host: "docs.example.org") == "Allow docs.example.org to open this link in Mail?")
        // A typed address (or a page with no web origin) has no site to name.
        #expect(PageText.externalAppQuestion(appName: "Mail", host: nil) == "Open this link in Mail?")
        #expect(PageText.externalAppQuestion(appName: "Mail", host: "about:blank") == "Open this link in Mail?")
    }

    // MARK: Downloads gate

    @Test func firstDownloadOfADocumentProceeds() {
        var gate = PageDownloadGate()
        #expect(gate.next(navigation: 1) == .proceed)
        #expect(gate.next(navigation: 1) == .ask)
    }

    @Test func allowedDownloadsProceedUntilTheDocumentChanges() {
        var gate = PageDownloadGate()
        _ = gate.next(navigation: 1)
        #expect(gate.next(navigation: 1) == .ask)
        gate.answer(allow: true, navigation: 1)
        #expect(gate.next(navigation: 1) == .proceed)
        #expect(gate.next(navigation: 1) == .proceed)
        // A new document starts over: its first proceeds, its second asks.
        #expect(gate.next(navigation: 2) == .proceed)
        #expect(gate.next(navigation: 2) == .ask)
    }

    @Test func refusedDownloadsStayRefusedUntilTheDocumentChanges() {
        var gate = PageDownloadGate()
        _ = gate.next(navigation: 3)
        #expect(gate.next(navigation: 3) == .ask)
        gate.answer(allow: false, navigation: 3)
        #expect(gate.next(navigation: 3) == .refuse)
        #expect(gate.next(navigation: 3) == .refuse)
        #expect(gate.next(navigation: 4) == .proceed)
    }

    @Test func anAnswerForAnOldDocumentIsIgnored() {
        var gate = PageDownloadGate()
        _ = gate.next(navigation: 1)
        _ = gate.next(navigation: 1)
        _ = gate.next(navigation: 2) // the page moved on while the question was up
        gate.answer(allow: true, navigation: 1)
        #expect(gate.next(navigation: 2) == .ask)
    }

    /// A page with no document left to compare (it closed) keeps the count it had.
    @Test func noNavigationKeepsTheCurrentDocument() {
        var gate = PageDownloadGate()
        #expect(gate.next(navigation: nil) == .proceed)
        #expect(gate.next(navigation: nil) == .ask)
        #expect(gate.next(navigation: 5) == .proceed)
        #expect(gate.next(navigation: nil) == .ask)
    }

    /// A page nobody has acted on: its first download asks first; later ones follow the several-files rules as usual.
    @Test func firstDownloadOfAnUntouchedPageAsksFirst() {
        var gate = PageDownloadGate()
        #expect(gate.next(navigation: 1, firstNeedsApproval: true) == .askFirst)
        // Whatever the answer, it counted as the first: the next one asks about several files.
        #expect(gate.next(navigation: 1, firstNeedsApproval: true) == .ask)
        gate.answer(allow: true, navigation: 1)
        #expect(gate.next(navigation: 1, firstNeedsApproval: true) == .proceed)
        // A new document starts over.
        #expect(gate.next(navigation: 2, firstNeedsApproval: true) == .askFirst)
        // A page the user has acted on proceeds as before.
        #expect(gate.next(navigation: 3, firstNeedsApproval: false) == .proceed)
    }

    @Test func downloadQuestionNamesTheSite() {
        #expect(PageText.downloadQuestion(host: "https://files.example.com/x") == "files.example.com wants to download a file")
        #expect(PageText.downloadQuestion(host: nil) == "This page wants to download a file")
        #expect(PageText.downloadDetail == "It will be saved to your Downloads folder.")
    }

    @Test func severalDownloadsQuestionNamesTheSite() {
        #expect(PageText.severalDownloadsQuestion(host: "https://files.example.com/x") == "files.example.com wants to download several files")
        #expect(PageText.severalDownloadsQuestion(host: nil) == "This page wants to download several files")
        #expect(PageText.severalDownloadsDetail == "Allow it to keep saving files to your Downloads folder?")
    }

    // MARK: Recently used

    @Test func recentlyUsedKeepsTheNewestWithinTheLimit() {
        var order: [Int] = []
        var evicted: [Int] = []
        for key in 1...4 {
            (order, evicted) = RecentlyUsed.use(key, in: order, limit: 3)
        }
        #expect(order == [2, 3, 4])
        #expect(evicted == [1])
        // Using a kept key moves it to the newest end without evicting.
        (order, evicted) = RecentlyUsed.use(2, in: order, limit: 3)
        #expect(order == [3, 4, 2])
        #expect(evicted.isEmpty)
        (order, evicted) = RecentlyUsed.use(5, in: order, limit: 3)
        #expect(order == [4, 2, 5])
        #expect(evicted == [3])
        // A lower limit drops several at once, oldest first.
        (order, evicted) = RecentlyUsed.use(6, in: order, limit: 1)
        #expect(order == [6])
        #expect(evicted == [4, 2, 5])
    }

    @Test func downloadRowsDescribeTheirState() {
        let id = UUID()
        func item(_ state: DownloadState) -> DownloadItem {
            DownloadItem(id: id, owner: .profile(id), filename: "a.txt", sourceHost: "example.com", state: state)
        }
        #expect(DownloadRowText.status(item(.running(fraction: 0.5))) == "50 percent")
        #expect(DownloadRowText.status(item(.running(fraction: nil))) == "Downloading…")
        #expect(DownloadRowText.status(item(.finished(URL(fileURLWithPath: "/tmp/a.txt")))) == "Done")
        #expect(DownloadRowText.status(item(.failed("Disk full"))) == "Failed: Disk full")
        #expect(DownloadRowText.status(item(.cancelled)) == "Cancelled")
        #expect(DownloadRowText.canCancel(item(.running(fraction: nil))))
        #expect(!DownloadRowText.canCancel(item(.cancelled)))
        #expect(DownloadRowText.finishedFile(item(.finished(URL(fileURLWithPath: "/tmp/a.txt"))))?.lastPathComponent == "a.txt")
        #expect(DownloadRowText.finishedFile(item(.failed("x"))) == nil)
        #expect(DownloadRowText.cancelLabel(item(.running(fraction: nil))) == "Cancel downloading a.txt")
        #expect(DownloadRowText.showInFinderLabel(item(.running(fraction: nil))) == "Show a.txt in Finder")
        #expect(DownloadRowText.canClear([item(.running(fraction: nil))]) == false)
        #expect(DownloadRowText.canClear([item(.cancelled)]))
    }
}
