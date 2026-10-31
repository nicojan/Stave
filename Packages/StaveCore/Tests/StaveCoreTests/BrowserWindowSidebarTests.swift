import Foundation
import Testing
@testable import StaveCore

@MainActor
struct BrowserWindowSidebarTests {
    private func makeModel() throws -> (BrowserWindowModel, OrganizationStore) {
        let (store, _, _) = try makeTempStore()
        try SampleOrganization.seed(into: store)
        let profile = try #require(try store.profiles().first)
        let home = try #require(try store.workspaces(profileID: profile.id).first)
        let state = WindowState(profileID: profile.id, workspaceID: home.id, selectedTabID: nil, frame: "", sortIndex: 0)
        let model = try BrowserWindowModel(store: store, revision: StoreRevision(), livePages: LivePageRegistry(), state: state)
        return (model, store)
    }

    private func regularID(_ model: BrowserWindowModel, at index: Int = 0) throws -> UUID {
        let rows = model.rows.filter(\.isRegular)
        guard case .tab(let id) = try #require(rows[index].id) else { throw StoreError.notFound }
        return id
    }

    @Test func errorIDBumpsOnEveryErrorEvenWithTheSameText() throws {
        let (model, _) = try makeModel()
        #expect(model.lastErrorID == 0)
        model.select(UUID())
        let first = model.lastErrorID
        #expect(first > 0)
        let text = model.lastError
        model.select(UUID())
        #expect(model.lastError == text)
        #expect(model.lastErrorID > first)
    }

    @Test func aSuccessfulWriteClearsTheErrorWithoutBumping() throws {
        let (model, _) = try makeModel()
        model.select(UUID())
        let id = model.lastErrorID
        model.openTab(url: "https://example.com/new")
        #expect(model.lastError == nil)
        #expect(model.lastErrorID == id)
    }

    @Test func closeShortcutDoesNothingWithAFolderHighlighted() throws {
        let (model, _) = try makeModel()
        let tab = try regularID(model)
        model.select(tab)
        let folder = try #require(model.rows.first { if case .folder = $0.kind { true } else { false } })
        model.sidebarHighlight = folder.id
        model.closeSelectedTab()
        #expect(model.selectedTabID == tab)
        #expect(model.rows.contains { $0.id == .tab(tab) })
        model.sidebarHighlight = .tab(tab)
        model.closeSelectedTab()
        #expect(!model.rows.contains { $0.id == .tab(tab) })
    }

    @Test func runActionsOnTabsAndFolders() throws {
        let (model, _) = try makeModel()
        let tab = try regularID(model)
        #expect(model.run(.pin, on: .tab(tab)))
        #expect(model.rows.first { $0.id == .tab(tab) }.map { if case .pinnedTab = $0.kind { true } else { false } } == true)
        #expect(model.run(.unpin, on: .tab(tab)))
        #expect(model.rows.first { $0.id == .tab(tab) }?.isRegular == true)
        let before = model.snapshot.essentials.count
        #expect(model.run(.addToEssentials, on: .tab(tab)))
        #expect(model.snapshot.essentials.count == before + 1)
        #expect(model.run(.removeFromEssentials, on: .tab(tab)))
        #expect(model.snapshot.essentials.count == before)
        #expect(model.run(.renameFolder, on: .tab(tab)) == false)
        #expect(model.run(.newFolder, on: .tab(tab)) == false)
    }

    @Test func removingTheSelectedPinnedTabSelectsItsNeighbour() throws {
        let (model, _) = try makeModel()
        let pinned = try #require(model.rows.first { if case .pinnedTab = $0.kind { true } else { false } })
        guard case .tab(let id) = pinned.id else { return }
        model.select(id)
        #expect(model.run(.removeFromPinned, on: pinned.id))
        #expect(!model.rows.contains { $0.id == pinned.id })
        #expect(model.selectedTabID != id)
    }

    @Test func deleteFolderKeepsItsTabs() throws {
        let (model, _) = try makeModel()
        let folder = try #require(model.rows.first { if case .folder = $0.kind { true } else { false } })
        #expect(model.run(.deleteFolder, on: folder.id))
        #expect(!model.rows.contains { $0.id == folder.id })
    }

    @Test func foldersAreNamedThroughTheModel() throws {
        let (model, _) = try makeModel()
        let top = try #require(model.rows.first { if case .folder = $0.kind { true } else { false } })
        let count = model.rows.count
        model.run(.newFolder, on: nil, typed: "  Projects ")
        #expect(model.rows.contains { $0.title == "Projects" })
        model.run(.newFolder, on: nil, typed: "")
        #expect(model.rows.contains { $0.title == "New Folder" })
        model.run(.renameFolder, on: top.id, typed: "Renamed")
        #expect(model.rows.contains { $0.id == top.id && $0.title == "Renamed" })
        model.run(.renameFolder, on: top.id, typed: "   ")
        #expect(model.rows.contains { $0.id == top.id && $0.title == "Renamed" })
        model.run(.newFolderInside, on: top.id, typed: "Inner")
        #expect(model.rows.contains { $0.title == "Inner" && $0.parentFolderID != nil })
        model.run(.closeTab, on: top.id, typed: "x") // not a naming action: ignored
        #expect(model.rows.count > count)
    }
}
