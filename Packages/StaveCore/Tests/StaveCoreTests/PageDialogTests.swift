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
        #expect(PopupFrame.title(pageTitle: "Sign in", url: "https://accounts.example.com/x") == "Sign in")
        #expect(PopupFrame.title(pageTitle: "  ", url: "https://accounts.example.com/x") == "accounts.example.com")
        #expect(PopupFrame.title(pageTitle: "", url: "") == "Pop-up")
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
