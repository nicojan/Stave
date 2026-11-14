import Foundation
import Testing
@testable import StaveCore

struct PageChromeTextTests {
    @Test func progressValueIsClamped() {
        #expect(PageChromeText.progressValue(-0.2) == "0 percent")
        #expect(PageChromeText.progressValue(0.5) == "50 percent")
        #expect(PageChromeText.progressValue(1.7) == "100 percent")
        #expect(PageChromeText.progressValue(.nan) == "0 percent")
        #expect(PageChromeText.progressValue(.infinity) == "100 percent")
        #expect(PageChromeText.progressValue(-.infinity) == "0 percent")
    }

    @Test func fixedTextsAreTheAgreedWords() {
        #expect(PageChromeText.loadingLabel == "Loading")
        #expect(PageChromeText.noSelection == "No tab selected")
        #expect(PageChromeText.dataNotOpen == "Stave's data is not open.")
        #expect(PageChromeText.sidebarWidth == "Sidebar width")
        #expect(PageChromeText.sidebarWidthValue(260.7) == "260 points")
    }

    @Test func contentBlockingDisabledOnBlank() {
        #expect(!PageMenuState.contentBlockingEnabled(url: "about:blank"))
        #expect(!PageMenuState.contentBlockingEnabled(url: "ABOUT:BLANK"))
        #expect(!PageMenuState.contentBlockingEnabled(url: ""))
        #expect(!PageMenuState.contentBlockingEnabled(url: "   "))
        #expect(!PageMenuState.contentBlockingEnabled(url: "file:///tmp/a.html"))
        #expect(!PageMenuState.contentBlockingEnabled(url: "data:text/html,x"))
        #expect(!PageMenuState.contentBlockingEnabled(url: "https://"))
        #expect(PageMenuState.contentBlockingEnabled(url: "https://example.com/a"))
        #expect(PageMenuState.contentBlockingEnabled(url: "http://example.org"))
        #expect(PageMenuState.blockingState(url: "about:blank", isOn: true) == nil)
        #expect(PageMenuState.blockingState(url: "https://example.com/", isOn: false) == false)
    }

    @Test func launchAlertsNameTheCause() {
        #expect(StoreErrorText.openFailure(StoreError.newerSchema).message.hasPrefix("This copy of Stave is older"))
        #expect(StoreErrorText.openFailure(StoreError.newerSchema).detail == nil)
        #expect(StoreErrorText.openFailure(StoreError.backupFailed).message == StoreErrorText.message(for: StoreError.backupFailed))
        let other = StoreErrorText.openFailure(CocoaError(.fileNoSuchFile))
        #expect(other.message == "Stave could not open its data.")
        #expect(other.detail?.isEmpty == false)
        #expect(StoreErrorText.unusableLaunchArgument("-StaveArcHome").message == "Stave did not start: -StaveArcHome needs an absolute path.")
    }

    @Test func profileMenuButtonTexts() {
        #expect(WorkspaceMenus.profileMenuHelp(profileName: "Work") == "Profile: Work")
        #expect(WorkspaceMenus.profileMenuLabel(profileName: "Work") == "Profile, Work")
    }

    @Test func moveTargetSymbolIsTheWorkspaceSymbolOrNone() {
        let profile = UUID()
        let symbol = Workspace(profileID: profile, name: "A", icon: "briefcase", colorHex: "#FFFFFF", sortIndex: 0)
        let blank = Workspace(profileID: profile, name: "B", icon: "", colorHex: "#FFFFFF", sortIndex: 1)
        let emoji = Workspace(profileID: profile, name: "C", icon: "🎮", colorHex: "#FFFFFF", sortIndex: 2)
        let all = [symbol, blank, emoji]
        func target(_ w: Workspace) -> TabMoveTarget { TabMoveTarget(workspaceID: w.id, title: SidebarMenus.moveTargetTitle(w.name)) }
        #expect(SidebarMenus.moveTargetSymbol(target(symbol), workspaces: all) == "briefcase")
        #expect(SidebarMenus.moveTargetSymbol(target(blank), workspaces: all) == WorkspaceIcon.fallbackSymbol)
        #expect(SidebarMenus.moveTargetSymbol(target(emoji), workspaces: all) == nil)
        #expect(SidebarMenus.moveTargetSymbol(TabMoveTarget(workspaceID: UUID(), title: "Move to Gone"), workspaces: all) == nil)
    }
}
