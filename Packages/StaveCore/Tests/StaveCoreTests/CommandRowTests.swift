import Foundation
import Testing
@testable import StaveCore

@MainActor
struct CommandRowTests {
    private let home = UUID()
    private let work = UUID()

    private func tab(_ title: String, url: String = "https://www.example.com/a", workspace: UUID?, name: String?) -> CommandResult {
        .tab(CommandTab(tab: Tab(slotID: UUID(), url: url, title: title), section: .regular, workspaceID: workspace, workspaceName: name))
    }

    private func row(_ result: CommandResult, engine: SearchEngine? = nil) -> CommandRow {
        CommandRows.row(for: result, currentWorkspaceID: home, engine: engine)
    }

    @Test func openRowShowsTheAddressWithoutHttps() {
        let found = row(.open(url: "https://example.net"))
        #expect(found.icon == .open)
        #expect(found.title == "Open example.net")
        #expect(found.secondary == "https://example.net")
        #expect(found.accessibilityLabel == "Open example.net, address")
        #expect(row(.open(url: "http://localhost:3000")).title == "Open http://localhost:3000")
    }

    @Test func searchRowNamesTheEngineOrAsksForOne() {
        let none = row(.search(query: "exa"))
        #expect(none.icon == .search)
        #expect(none.title == "Search for exa")
        #expect(none.secondary == "Choose a search engine")
        #expect(none.accessibilityLabel == "Search for exa, search")
        #expect(row(.search(query: "exa"), engine: .duckDuckGo).secondary == "DuckDuckGo")
    }

    @Test func tabInThisWorkspaceShowsItsHost() {
        let found = row(tab("Docs", workspace: home, name: "Home"))
        #expect(found.icon == .tab)
        #expect(found.title == "Docs")
        #expect(found.secondary == "example.com")
        #expect(found.accessibilityLabel == "Docs, tab")
    }

    @Test func tabInAnotherWorkspaceShowsAndSaysTheWorkspace() {
        let found = row(tab("Docs", workspace: work, name: "Work"))
        #expect(found.secondary == "Work")
        #expect(found.accessibilityLabel == "Docs, tab, in Work")
    }

    @Test func essentialTabHasNoWorkspace() {
        let found = row(tab("Mail", workspace: nil, name: nil))
        #expect(found.secondary == "example.com")
        #expect(found.accessibilityLabel == "Mail, tab")
    }

    @Test func addresslessUntitledTabIsNewTabWithNoSecondary() {
        let found = row(tab("", url: "", workspace: home, name: "Home"))
        #expect(found.title == "New Tab")
        #expect(found.secondary == nil)
    }

    @Test func archivedRow() {
        let found = row(.archived(ArchivedTab(profileID: UUID(), url: "https://example.org/y", title: "Old page")))
        #expect(found.icon == .archived)
        #expect(found.secondary == "Archived")
        #expect(found.accessibilityLabel == "Old page, archived tab")
    }

    @Test func workspaceAndActionRows() {
        let space = Workspace(profileID: UUID(), name: "Work", icon: "briefcase", colorHex: "#FFFFFF", sortIndex: 1)
        let workspace = row(.workspace(space))
        #expect(workspace.icon == .workspace(.symbol("briefcase")))
        #expect(workspace.icon.symbolName == "briefcase")
        #expect(workspace.accessibilityLabel == "Work, workspace")
        #expect(row(.workspace(Workspace(profileID: UUID(), name: "Fun", icon: "🎉", colorHex: "#FFFFFF", sortIndex: 2))).icon.symbolName == nil)
        let action = row(.action(.showArchive))
        #expect(action.icon == .action)
        #expect(action.title == "Show Archive")
        #expect(action.accessibilityLabel == "Show Archive, action")
    }

    @Test func javascriptTextIsASearchRowNotAnOpenRow() {
        let model = CommandBarModel(mode: .newTab, candidates: CommandCandidates(), currentURL: nil)
        model.query = "javascript:alert(1)"
        #expect(model.rows.first?.icon == .search)
        #expect(model.rows.first?.title == "Search for javascript:alert(1)")
    }
}
