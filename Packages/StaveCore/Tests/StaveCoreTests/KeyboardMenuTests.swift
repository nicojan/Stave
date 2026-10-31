import Foundation
import Testing
@testable import StaveCore

/// The Tab and Workspaces menus are the keyboard route to what the context menus and VoiceOver actions offer; they read the same lists.
struct KeyboardMenuTests {
    private let profile = Profile(name: "P", sortIndex: 0)
    private let essentialA = Tab(slotID: UUID(), url: "https://example.com/a", title: "A")
    private let essentialB = Tab(slotID: UUID(), url: "https://example.com/b", title: "B")
    private let pinned = Tab(slotID: UUID(), pinnedURL: "https://example.com/p", url: "https://example.com/p", title: "P")
    private let drifted = Tab(slotID: UUID(), pinnedURL: "https://example.com/d", url: "https://example.com/d2", title: "D")
    private let regularOne = Tab(slotID: UUID(), url: "https://example.org/1", title: "One")
    private let regularTwo = Tab(slotID: UUID(), url: "https://example.org/2", title: "Two")
    private let workspace: Workspace
    private let folder: Folder
    private let nested: Folder

    init() {
        workspace = Workspace(profileID: profile.id, name: "Home", icon: "", colorHex: "#8E8E93", sortIndex: 0)
        folder = Folder(workspaceID: workspace.id, title: "Reading", sortIndex: 0)
        nested = Folder(workspaceID: workspace.id, parentFolderID: folder.id, title: "Later", sortIndex: 0)
    }

    private var snapshot: SidebarSnapshot {
        SidebarSnapshot(
            profile: profile, workspace: workspace, essentials: [essentialA, essentialB],
            pinned: [.folder(folder, children: [.folder(nested, children: [])]), .tab(pinned), .tab(drifted)],
            regular: [regularOne, regularTwo]
        )
    }

    private var rows: [SidebarRow] { SidebarRows.build(snapshot, containers: []) }

    private func menu(_ highlight: SidebarItemID?) -> [SidebarAction] {
        SidebarMenus.menuActions(highlight: highlight, rows: rows, snapshot: snapshot)
    }

    @Test func nothingHighlightedOffersOnlyNewFolder() {
        #expect(menu(nil) == [.newFolder])
        #expect(menu(.tab(UUID())) == [.newFolder])
        #expect(menu(.folder(UUID())) == [.newFolder])
    }

    @Test func aRegularTabOffersPinAndEssentialsButNotCloseTab() {
        #expect(menu(.tab(regularOne.id)) == [.pin, .addToEssentials, .newFolder])
    }

    @Test func aPinnedTabOffersUnpinAndRemoveAndBackOnlyWhenDrifted() {
        #expect(menu(.tab(pinned.id)) == [.unpin, .addToEssentials, .removeFromPinned, .newFolder])
        #expect(menu(.tab(drifted.id)) == [.unpin, .addToEssentials, .backToPinnedPage, .removeFromPinned, .newFolder])
    }

    @Test func anEssentialOffersRemoveFromEssentials() {
        #expect(menu(.tab(essentialA.id)) == [.removeFromEssentials, .newFolder])
    }

    @Test func foldersOfferRenameDeleteAndNewInsideOnlyAtTopLevel() {
        #expect(menu(.folder(folder.id)) == [.renameFolder, .newFolderInside, .deleteFolder, .newFolder])
        #expect(menu(.folder(nested.id)) == [.renameFolder, .deleteFolder, .newFolder])
    }

    @Test func theMenuOffersNothingTheContextMenuDoesNot() {
        for row in rows {
            let contextual = Set(SidebarMenus.actions(for: row))
            let offered = Set(menu(row.id)).subtracting([.newFolder])
            #expect(offered.isSubset(of: contextual))
            #expect(offered == contextual.subtracting([.closeTab]))
        }
    }

    @Test func movesFollowTheKeyboardMoveRule() {
        #expect(!SidebarMenus.canMove(highlight: nil, by: 1, snapshot: snapshot))
        #expect(!SidebarMenus.canMove(highlight: .tab(regularOne.id), by: -1, snapshot: snapshot))
        #expect(SidebarMenus.canMove(highlight: .tab(regularOne.id), by: 1, snapshot: snapshot))
        #expect(SidebarMenus.canMove(highlight: .tab(regularTwo.id), by: -1, snapshot: snapshot))
        #expect(!SidebarMenus.canMove(highlight: .tab(regularTwo.id), by: 1, snapshot: snapshot))
        #expect(SidebarMenus.canMove(highlight: .tab(essentialA.id), by: 1, snapshot: snapshot))
        #expect(!SidebarMenus.canMove(highlight: .tab(essentialA.id), by: -1, snapshot: snapshot))
    }

    @Test func menuTitlesAreNonEmptyAndAskingActionsEndInAnEllipsis() {
        for action in SidebarAction.allCases {
            #expect(!action.menuTitle.isEmpty)
            #expect(action.menuTitle.hasSuffix("…") == action.needsTitle)
        }
        for action in WorkspaceAction.allCases { #expect(!action.menuTitle.isEmpty) }
    }

    @Test func workspaceMenuAlwaysListsAllFourAndEnablesLikeTheContextMenu() {
        for (index, count) in [(0, 1), (0, 3), (1, 3), (2, 3)] {
            let items = WorkspaceMenus.menuItems(index: index, count: count)
            #expect(items.map(\.action) == [.edit, .moveLeft, .moveRight, .delete])
            let offered = Set(WorkspaceMenus.items(index: index, count: count).filter(\.isEnabled).map(\.action))
            #expect(Set(items.filter(\.isEnabled).map(\.action)) == offered)
        }
        #expect(WorkspaceMenus.menuItems(index: 0, count: 1).map(\.isEnabled) == [true, false, false, false])
        #expect(WorkspaceMenus.menuItems(index: 1, count: 3).map(\.isEnabled) == [true, true, true, true])
    }

    @Test func theNewMenuCommandsWaitForASheet() {
        #expect(!MenuCommandGate.allowedWhileSheetUp(.workspaceAction))
        #expect(!MenuCommandGate.allowedWhileSheetUp(.sidebarAction))
    }
}
