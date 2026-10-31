import Foundation
import Testing
@testable import StaveCore

struct SidebarMenusTests {
    private func row(_ kind: SidebarRow.Kind, parent: UUID? = nil, id: SidebarItemID = .tab(UUID())) -> SidebarRow {
        SidebarRow(id: id, kind: kind, depth: parent == nil ? 0 : 1, parentFolderID: parent, title: "t", containerColorHex: nil, accessibilityLabel: "t")
    }

    @Test func regularTabMenu() {
        #expect(SidebarMenus.actions(for: row(.regularTab)) == [.pin, .addToEssentials, .closeTab])
    }

    @Test func pinnedTabMenuOffersBackOnlyWhenDrifted() {
        #expect(SidebarMenus.actions(for: row(.pinnedTab(drifted: false))) == [.unpin, .addToEssentials, .closeTab, .removeFromPinned])
        #expect(SidebarMenus.actions(for: row(.pinnedTab(drifted: true))) == [.unpin, .addToEssentials, .backToPinnedPage, .closeTab, .removeFromPinned])
    }

    @Test func newFolderInsideOnlyAtTopLevel() {
        let top = row(.folder(isOpen: true, childCount: 0), id: .folder(UUID()))
        let nested = row(.folder(isOpen: true, childCount: 0), parent: UUID(), id: .folder(UUID()))
        #expect(SidebarMenus.actions(for: top) == [.renameFolder, .newFolderInside, .deleteFolder])
        #expect(SidebarMenus.actions(for: nested) == [.renameFolder, .deleteFolder])
    }

    @Test func essentialAndHeaderMenus() {
        let plain = Tab(slotID: UUID(), pinnedURL: "https://example.com/", url: "https://example.com/", title: "A")
        var drifted = plain
        drifted.url = "https://example.com/other"
        #expect(SidebarMenus.actions(forEssential: plain) == [.removeFromEssentials])
        #expect(SidebarMenus.actions(forEssential: drifted) == [.backToPinnedPage, .removeFromEssentials])
        #expect(SidebarMenus.pinnedHeaderActions == [.newFolder])
    }

    @Test func everyActionHasATitleAndSymbol() {
        for action in SidebarAction.allCases {
            #expect(!action.title.isEmpty)
            #expect(!action.symbol.isEmpty)
        }
        #expect(SidebarAction.allCases.filter(\.needsTitle) == [.renameFolder, .newFolderInside, .newFolder])
    }

    @Test func folderTitlePrompt() {
        #expect(SidebarMenus.folderTitle(typed: "  Reading  ", action: .renameFolder) == "Reading")
        #expect(SidebarMenus.folderTitle(typed: "  ", action: .renameFolder) == nil)
        #expect(SidebarMenus.folderTitle(typed: "", action: .newFolder) == "New Folder")
        #expect(SidebarMenus.promptPrefill(action: .renameFolder, currentTitle: "Old") == "Old")
        #expect(SidebarMenus.promptPrefill(action: .newFolderInside, currentTitle: "Old") == "")
    }

    @Test func regularRowFlag() {
        #expect(row(.regularTab).isRegular)
        #expect(!row(.pinnedTab(drifted: false)).isRegular)
    }

    // MARK: - Keys

    @Test func closeShortcutFallsBackToTheSelectionOnlyWithNoHighlight() {
        let tab = UUID(), other = UUID()
        #expect(SidebarKeys.closeShortcutTarget(highlight: .tab(tab), selected: other) == tab)
        #expect(SidebarKeys.closeShortcutTarget(highlight: .folder(UUID()), selected: other) == nil)
        #expect(SidebarKeys.closeShortcutTarget(highlight: nil, selected: other) == other)
        #expect(SidebarKeys.closeShortcutTarget(highlight: nil, selected: nil) == nil)
    }

    @Test func deleteKeyActsOnlyOnAHighlightedTabRow() {
        let tab = UUID()
        #expect(SidebarKeys.deleteKeyTarget(highlight: .tab(tab)) == tab)
        #expect(SidebarKeys.deleteKeyTarget(highlight: .folder(UUID())) == nil)
        #expect(SidebarKeys.deleteKeyTarget(highlight: nil) == nil)
    }

    @Test func viewTextRules() {
        #expect(SidebarText.disclosureLabel(isOpen: true, title: "Reading") == "Close folder Reading")
        #expect(SidebarText.disclosureLabel(isOpen: false, title: "Reading") == "Open folder Reading")
        #expect(SidebarText.driftedLabel(title: "Post 42") == "Back to pinned page, Post 42")
        #expect(SidebarText.promptConfirm(for: .renameFolder) == "Rename")
        #expect(SidebarText.promptConfirm(for: .newFolder) == "Create")
        #expect(SidebarText.promptConfirm(for: .newFolderInside) == "Create")
        #expect(SidebarText.restoreLabel(title: "Old receipt") == "Restore Old receipt")
        let tab = Tab(slotID: UUID(), url: "https://example.com/", title: "T")
        #expect(AddressFieldText.isPlaceholder(for: nil))
        #expect(AddressFieldText.isPlaceholder(for: Tab(slotID: UUID(), url: "", title: "")))
        #expect(!AddressFieldText.isPlaceholder(for: tab))
    }

    @Test func arrowsOpenAndCloseAFolder() {
        let id = UUID()
        let open = [row(.folder(isOpen: true, childCount: 1), id: .folder(id))]
        let closed = [row(.folder(isOpen: false, childCount: 1), id: .folder(id))]
        #expect(SidebarKeys.folderChange(highlight: .folder(id), key: .left, rows: open)?.isOpen == false)
        #expect(SidebarKeys.folderChange(highlight: .folder(id), key: .right, rows: open) == nil)
        #expect(SidebarKeys.folderChange(highlight: .folder(id), key: .right, rows: closed)?.isOpen == true)
        #expect(SidebarKeys.folderChange(highlight: .folder(id), key: .left, rows: closed) == nil)
        #expect(SidebarKeys.folderChange(highlight: .tab(id), key: .left, rows: open) == nil)
        #expect(SidebarKeys.folderChange(highlight: .folder(UUID()), key: .left, rows: open) == nil)
        #expect(SidebarKeys.folderChange(highlight: nil, key: .left, rows: open) == nil)
    }

    // MARK: - Address text

    @Test func addressFieldText() {
        let tab = Tab(slotID: UUID(), url: "https://www.example.com/a/b", title: "T")
        #expect(AddressFieldText.text(for: tab) == "example.com")
        #expect(AddressFieldText.accessibilityLabel(for: tab) == "Address, example.com")
        let blank = Tab(slotID: UUID(), url: "", title: "")
        #expect(AddressFieldText.text(for: blank) == AddressFieldText.placeholder)
        #expect(AddressFieldText.text(for: nil) == AddressFieldText.placeholder)
        #expect(AddressFieldText.accessibilityLabel(for: nil) == "Address, empty")
    }

    // MARK: - Archive

    private func archived(_ title: String, _ url: String, age: TimeInterval) -> ArchivedTab {
        ArchivedTab(profileID: UUID(), url: url, title: title, closedAt: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    @Test func archiveIsNewestFirstAndFiltersByTitleOrURL() {
        let old = archived("Old receipt", "https://example.com/old-1", age: 100)
        let new = archived("Closed forum thread", "https://example.net/old-2", age: 10)
        let mid = archived("Café menu", "https://example.org/menu", age: 50)
        let all = [old, new, mid]
        #expect(ArchiveFilter.results(all, query: "").map(\.id) == [new.id, mid.id, old.id])
        #expect(ArchiveFilter.results(all, query: "  ").map(\.id) == [new.id, mid.id, old.id])
        #expect(ArchiveFilter.results(all, query: "receipt").map(\.id) == [old.id])
        #expect(ArchiveFilter.results(all, query: "example.net").map(\.id) == [new.id])
        #expect(ArchiveFilter.results(all, query: "cafe").map(\.id) == [mid.id])
        #expect(ArchiveFilter.results(all, query: "zzz").isEmpty)
    }

    @Test func archiveEmptyMessagesAndRestoreTarget() {
        #expect(ArchiveFilter.emptyMessage(archiveCount: 0) == "Nothing in the archive")
        #expect(ArchiveFilter.emptyMessage(archiveCount: 3) == "No matches")
        let a = archived("A", "https://example.com/a", age: 1), b = archived("B", "https://example.com/b", age: 2)
        #expect(ArchiveFilter.restoreTarget(in: [a, b], selected: b.id) == b.id)
        #expect(ArchiveFilter.restoreTarget(in: [a, b], selected: UUID()) == a.id)
        #expect(ArchiveFilter.restoreTarget(in: [a, b], selected: nil) == a.id)
        #expect(ArchiveFilter.restoreTarget(in: [], selected: nil) == nil)
    }

    // MARK: - Hex

    @Test func hexParsing() {
        #expect(HexColor.rgb("#FF8000") == RGBColor(red: 1, green: 128.0 / 255, blue: 0))
        #expect(HexColor.rgb("00ff00") == RGBColor(red: 0, green: 1, blue: 0))
        for bad in ["", "#", "#FFF", "#FFFFFFF", "#GGGGGG", "+12345", "-12345", "#１２３４５６", " #FFFFFF", "#FFFFF "] {
            #expect(HexColor.rgb(bad) == nil, "\(bad)")
        }
    }
}
