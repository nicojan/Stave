import Foundation
import Testing
@testable import StaveCore

/// Enablement of View ▸ Zoom In / Zoom Out / Actual Size, File ▸ Print… and Develop ▸ Show Web Inspector / Show Page Source
/// (decisions 12–14), and their titles.
struct PageToolsMenuTests {
    private func web(zoom: Double = 1.0, inspector: Bool = true, source: Bool = true) -> PageStatusSummary {
        PageStatusSummary(hasPage: true, zoom: zoom, inspectorAvailable: inspector, sourceAvailable: source)
    }

    /// Decision 13: a blank tab or a failure panel has nothing to print. The page commands also go with no page, a sheet, or the History view.
    @Test func printDisabledOnBlankAndFailure() {
        #expect(PageMenuState.from(status: web(), sheetOpen: false).canPrint)
        var blank = web()
        blank.isBlank = true
        #expect(!PageMenuState.from(status: blank, sheetOpen: false).canPrint)
        var failed = web()
        failed.hasFailure = true
        #expect(!PageMenuState.from(status: failed, sheetOpen: false).canPrint)
        #expect(!PageMenuState.from(status: nil, sheetOpen: false).canPrint)
        #expect(!PageMenuState.from(status: web(), sheetOpen: true).canPrint)
        #expect(!PageMenuState.from(status: web(), sheetOpen: false, historyShown: true).canPrint)
    }

    /// Zoom In stops at 300 %, Zoom Out at 50 %, and Actual Size is off at 100 % (as in Safari).
    @Test func zoomItemsDisabledAtTheEnds() {
        let normal = PageMenuState.from(status: web(), sheetOpen: false)
        #expect(normal.canZoomIn && normal.canZoomOut && !normal.canResetZoom)
        let most = PageMenuState.from(status: web(zoom: 3.0), sheetOpen: false)
        #expect(!most.canZoomIn && most.canZoomOut && most.canResetZoom)
        let least = PageMenuState.from(status: web(zoom: 0.5), sheetOpen: false)
        #expect(least.canZoomIn && !least.canZoomOut && least.canResetZoom)
        var failed = web(zoom: 1.5)
        failed.hasFailure = true
        let onFailure = PageMenuState.from(status: failed, sheetOpen: false)
        #expect(!onFailure.canZoomIn && !onFailure.canZoomOut && !onFailure.canResetZoom)
        let overHistory = PageMenuState.from(status: web(zoom: 1.5), sheetOpen: false, historyShown: true)
        #expect(!overHistory.canZoomIn && !overHistory.canZoomOut && !overHistory.canResetZoom)
    }

    /// Decision 14: each Develop item is disabled when the private piece it needs is missing (or, in a private window, turned off). A blank
    /// page can be inspected but has no source; a failure panel hides the page, so neither applies.
    @Test func developItemsNeedTheirPiece() {
        let full = PageMenuState.from(status: web(), sheetOpen: false)
        #expect(full.canInspect && full.canShowSource)
        let missing = PageMenuState.from(status: web(inspector: false, source: false), sheetOpen: false)
        #expect(!missing.canInspect && !missing.canShowSource)
        var blank = web()
        blank.isBlank = true
        let onBlank = PageMenuState.from(status: blank, sheetOpen: false)
        #expect(onBlank.canInspect && !onBlank.canShowSource)
        var failed = web()
        failed.hasFailure = true
        let onFailure = PageMenuState.from(status: failed, sheetOpen: false)
        #expect(!onFailure.canInspect && !onFailure.canShowSource)
        #expect(!PageMenuState.from(status: web(), sheetOpen: true).canInspect)
        #expect(!PageMenuState.disabled.canInspect && !PageMenuState.disabled.canPrint && !PageMenuState.disabled.canZoomIn)
    }

    @Test func blankMeansNoAddressOrAboutBlank() {
        #expect(PageMenuState.isBlank(url: ""))
        #expect(PageMenuState.isBlank(url: "about:blank"))
        #expect(!PageMenuState.isBlank(url: "https://example.com/"))
        #expect(!PageMenuState.isBlank(url: "file:///tmp/a.html"))
    }

    /// The print job is named after the page (decision 13), else its host, else its address, never blank.
    @Test func printJobIsNamedAfterThePage() {
        #expect(PageMenuText.printJobTitle(title: "Invented Title", url: "https://example.com/a") == "Invented Title")
        #expect(PageMenuText.printJobTitle(title: "  \n", url: "https://www.Example.com:8443/a") == "example.com")
        #expect(PageMenuText.printJobTitle(title: "", url: "file:///tmp/page.html") == "file:///tmp/page.html")
        #expect(PageMenuText.printJobTitle(title: "", url: "") == DisplayText.newTabTitle)
    }

    @Test func menuTitlesUseSafarisNames() {
        #expect(PageMenuText.zoomIn == "Zoom In")
        #expect(PageMenuText.zoomOut == "Zoom Out")
        #expect(PageMenuText.actualSize == "Actual Size")
        #expect(PageMenuText.print == "Print…")
        #expect(PageMenuText.developMenu == "Develop")
        #expect(PageMenuText.showWebInspector == "Show Web Inspector")
        #expect(PageMenuText.showPageSource == "Show Page Source")
    }
}
