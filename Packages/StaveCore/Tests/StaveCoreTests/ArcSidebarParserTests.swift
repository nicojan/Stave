import Foundation
import Testing
@testable import StaveCore

struct ArcSidebarParserTests {
    private func basic() throws -> ArcSidebar {
        try ArcSidebarParser.parse(try arcFixture("basic"))
    }

    @Test func basicSpacesInSidebarOrder() throws {
        let sidebar = try basic()
        #expect(sidebar.spaces.map(\.title) == ["Work", nil])
        #expect(sidebar.spaces.map(\.profile) == [.default, .default])
    }

    @Test func basicPinnedTreeFollowsChildrenIds() throws {
        let sidebar = try basic()
        let spec = ArcTab(url: "https://spec.example.com/draft", title: "Draft Spec")
        let notes = ArcTab(url: "https://notes.example.com/daily", title: "Daily Notes")
        let board = ArcTab(url: "https://board.example.com/team", title: "My Board")
        #expect(sidebar.spaces[0].pinned == [
            .folder(title: "Docs", children: [.tab(spec), .tab(notes)]),
            .tab(board),
        ])
        #expect(sidebar.spaces[1].pinned == [
            .tab(ArcTab(url: "https://recipes.example.com/soup", title: "Soup")),
        ])
        #expect(sidebar.spaces[1].unpinned.isEmpty)
    }

    @Test func basicUnpinnedAndFavorites() throws {
        let sidebar = try basic()
        #expect(sidebar.spaces[0].unpinned == [
            .tab(ArcTab(url: "https://mail.example.com/inbox", title: "Inbox")),
            .tab(ArcTab(url: "https://calendar.example.com/week", title: "Week View")),
        ])
        let favorites = try #require(sidebar.favorites[.default])
        #expect(favorites == [
            .tab(ArcTab(url: "https://chat.example.com/", title: "Chat")),
            .tab(ArcTab(url: "https://music.example.com/", title: "Music")),
        ])
        #expect(sidebar.duplicateItems == 0)
    }

    @Test func basicIconAndColour() throws {
        let sidebar = try basic()
        #expect(sidebar.spaces[0].emoji == "\u{1F4BC}")
        #expect(sidebar.spaces[0].colorHex == "#5C6BF2")
        #expect(sidebar.spaces[1].emoji == nil)
        #expect(sidebar.spaces[1].colorHex == nil)
    }

    @Test func rejectsNonJSON() {
        #expect(throws: ArcImportError.notJSON) { try ArcSidebarParser.parse(Data("nope".utf8)) }
    }

    @Test func rejectsMissingSidebar() {
        let data = Data(#"{"sidebar":{"containers":[{"global":{}}]}}"#.utf8)
        #expect(throws: ArcImportError.noSidebar) { try ArcSidebarParser.parse(data) }
    }

    @Test func rejectsOversizeFile() {
        let data = Data(count: ArcSidebarParser.maximumFileSize + 1)
        #expect(throws: ArcImportError.fileTooLarge) { try ArcSidebarParser.parse(data) }
    }
}
