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

    // MARK: - Edge cases

    private func edge() throws -> ArcSidebar {
        try ArcSidebarParser.parse(try arcFixture("edge-cases"))
    }

    private let profile1 = ArcProfileKey.custom(directoryBasename: "Profile 1")
    private let profile9 = ArcProfileKey.custom(directoryBasename: "Profile 9")

    @Test func legacyContainerIDsWithUnpinnedFirst() throws {
        let sidebar = try edge()
        #expect(sidebar.spaces.map(\.title) == ["Acme", "Odd"])
        guard case .folder(let title, _)? = sidebar.spaces[0].pinned.first else {
            Issue.record("Acme's pinned list should start with a folder")
            return
        }
        #expect(title == "Level 1")
        #expect(sidebar.spaces[0].unpinned.count == 2)
        // T-SHARED is a repeat here, so only the CYC folder remains.
        #expect(sidebar.spaces[1].pinned.count == 1)
        #expect(sidebar.spaces[1].unpinned.isEmpty)
    }

    @Test func customAndUnrecognizedProfiles() throws {
        let sidebar = try edge()
        #expect(sidebar.spaces[0].profile == profile1)
        #expect(sidebar.spaces[1].profile == .unrecognized)
    }

    @Test func favoritesKeyedByContainerMarker() throws {
        let sidebar = try edge()
        #expect(sidebar.favorites[profile1] == [
            .folder(title: "Fav Folder", children: [
                .tab(ArcTab(url: "https://fav-inner.example.com/", title: "Fav Inner")),
            ]),
            .tab(ArcTab(url: "https://fav-plain.example.org/", title: "Fav Plain")),
        ])
        #expect(sidebar.favorites[profile9] == [])
        #expect(sidebar.favorites.count == 2)
    }

    @Test func deepFoldersAreKeptForThePlanner() throws {
        let sidebar = try edge()
        let deep = ArcTab(url: "https://deep.example.com/", title: "Deep")
        #expect(sidebar.spaces[0].pinned.first == .folder(title: "Level 1", children: [
            .folder(title: "Level 2", children: [
                .folder(title: "Level 3", children: [.tab(deep)]),
            ]),
        ]))
    }

    @Test func cycleAndSharedChildImportOnce() throws {
        let sidebar = try edge()
        let shared = ArcTab(url: "https://shared.example.com/", title: "Shared")
        #expect(sidebar.spaces[0].pinned.last == .tab(shared))
        #expect(sidebar.spaces[1].pinned == [.folder(title: "Cycle", children: [])])
        #expect(sidebar.duplicateItems == 2)
    }

    @Test func unknownKindsAreUnsupportedNodes() throws {
        let pinned = try edge().spaces[0].pinned
        #expect(pinned.contains(.unsupported(kind: "easel", title: "Sketch")))
        #expect(pinned.contains(.unsupported(kind: "welcomeToArc", title: nil)))
    }

    @Test func nonWebAndMissingURLsAreKeptForThePlanner() throws {
        let pinned = try edge().spaces[0].pinned
        let urls = pinned.compactMap { node -> String? in
            if case .tab(let tab) = node { return tab.url }
            return nil
        }
        #expect(urls.contains("javascript:alert(1)"))
        #expect(urls.contains("JavaScript:void(0)"))
        #expect(urls.contains("file:///etc/hosts"))
        #expect(urls.filter { $0.isEmpty }.count == 2)
    }

    @Test func splitViewsKeepTheirTabs() throws {
        let sidebar = try edge()
        guard case .split(let tabs) = sidebar.spaces[0].pinned[1] else {
            Issue.record("expected a split")
            return
        }
        #expect(tabs.map(\.title) == ["Split A", "Split B"])
        guard case .split(let unpinnedTabs) = sidebar.spaces[0].unpinned[0] else {
            Issue.record("expected a split")
            return
        }
        #expect(unpinnedTabs.count == 2)
    }

    @Test func longMixedScriptTitleIsKeptVerbatim() throws {
        let pinned = try edge().spaces[0].pinned
        let long = pinned.compactMap { node -> ArcTab? in
            if case .tab(let tab) = node, tab.url == "https://long.example.net/" { return tab }
            return nil
        }.first
        let title = try #require(long).title
        #expect(title.count == 300)
        #expect(title.hasPrefix("東京🚀Ünïcødé"))
    }

    // MARK: - Walk limits

    private func sidebarJSON(items: String, children: [String]) -> Data {
        let ids = children.map { "\"\($0)\"" }.joined(separator: ",")
        return Data("""
        {"sidebar":{"containers":[{"items":["PIN",{"id":"PIN","parentID":null,"childrenIds":[\(ids)],"data":{"itemContainer":{}}}\(items)],\
        "spaces":["S",{"id":"S","title":"S","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"PIN"]}]}]}}
        """.utf8)
    }

    @Test func repeatedChildIDsImportOnce() throws {
        let tab = #","T",{"id":"T","parentID":"PIN","childrenIds":[],"data":{"tab":{"savedURL":"https://once.example.com/"}}}"#
        let data = sidebarJSON(items: tab, children: Array(repeating: "T", count: 1000))
        let sidebar = try ArcSidebarParser.parse(data)
        #expect(sidebar.spaces[0].pinned == [.tab(ArcTab(url: "https://once.example.com/", title: ""))])
        #expect(sidebar.duplicateItems == 999)
    }

    @Test(.timeLimit(.minutes(1))) func doublingFoldersDoNotExplode() throws {
        // Each folder lists the next one twice: 2^40 paths without a visited set.
        var items = ""
        for level in 1...40 {
            let next = level == 40 ? "[]" : #"["F\#(level + 1)","F\#(level + 1)"]"#
            items += #","F\#(level)",{"id":"F\#(level)","childrenIds":\#(next),"title":"F\#(level)","data":{"list":{}}}"#
        }
        let sidebar = try ArcSidebarParser.parse(sidebarJSON(items: items, children: ["F1"]))
        #expect(sidebar.duplicateItems == 39)
    }

    private func nestedFolders(depth: Int) -> Data {
        var items = ""
        for level in 1...depth {
            let next = level == depth ? "[]" : #"["F\#(level + 1)"]"#
            items += #","F\#(level)",{"id":"F\#(level)","childrenIds":\#(next),"title":"F","data":{"list":{}}}"#
        }
        return sidebarJSON(items: items, children: ["F1"])
    }

    @Test func nestingAtTheMaximumDepthParses() throws {
        let sidebar = try ArcSidebarParser.parse(nestedFolders(depth: ArcSidebarParser.maximumDepth))
        #expect(sidebar.spaces[0].pinned.count == 1)
    }

    @Test func nestingPastTheMaximumDepthThrows() {
        let data = nestedFolders(depth: ArcSidebarParser.maximumDepth + 1)
        #expect(throws: ArcImportError.tooDeep) { try ArcSidebarParser.parse(data) }
    }

    @Test func sameProfileFavoritesAreConcatenatedInContainerOrder() throws {
        func container(_ id: String, _ tabID: String, _ url: String) -> String {
            #",""# + id + #"",{"id":""# + id + #"","parentID":null,"childrenIds":[""# + tabID
                + #""],"data":{"itemContainer":{"containerType":{"topApps":{"_0":{"default":true}}}}}},""#
                + tabID + #"",{"id":""# + tabID + #"","parentID":""# + id
                + #"","childrenIds":[],"data":{"tab":{"savedURL":""# + url + #""}}}"#
        }
        let items = container("FAV-B", "TB", "https://b.example.com/") + container("FAV-A", "TA", "https://a.example.com/")
        let json = """
        {"sidebar":{"containers":[{"items":["X",{"id":"X","data":{}}\(items)],"topAppsContainerIDs":["FAV-B",{"default":true},"FAV-A",{"default":true}],"spaces":[]}]}}
        """
        let sidebar = try ArcSidebarParser.parse(Data(json.utf8))
        #expect(sidebar.favorites[.default] == [
            .tab(ArcTab(url: "https://b.example.com/", title: "")),
            .tab(ArcTab(url: "https://a.example.com/", title: "")),
        ])
    }

    // MARK: - Profile names

    @Test func profileNamesFromLocalState() throws {
        let names = ArcProfileNames.names(fromLocalState: try arcFixture("local-state"))
        #expect(names == ["Default": "Person 1", "Profile 1": "Client Work"])
        #expect(ArcProfileNames.names(fromLocalState: Data("x".utf8)) == [:])
        #expect(ArcProfileNames.names(fromLocalState: Data("[]".utf8)) == [:])
    }

    // MARK: - Fix wave

    private let defaultMarker = #"{"default":true}"#

    @Test func favoritesWithUnrecognizedMarkerGoToDefaultAfterItsOwn() throws {
        let items = [
            arcFavoritesJSON("FAV-D", children: ["TD"], marker: defaultMarker),
            arcTabJSON("TD", parent: "FAV-D", url: "https://d.example.com/"),
            arcFavoritesJSON("FAV-A", children: ["TA"], marker: #"{"something":{}}"#),
            arcTabJSON("TA", parent: "FAV-A", url: "https://a.example.com/"),
            arcFavoritesJSON("FAV-B", children: ["TB"], marker: nil),
            arcTabJSON("TB", parent: "FAV-B", url: "https://b.example.com/"),
        ]
        let sidebar = try ArcSidebarParser.parse(arcSidebarData(items: items, spaces: []))
        #expect(sidebar.favorites[.default] == [
            .tab(ArcTab(url: "https://d.example.com/", title: "")),
            .tab(ArcTab(url: "https://a.example.com/", title: "")),
            .tab(ArcTab(url: "https://b.example.com/", title: "")),
        ])
        #expect(sidebar.favorites[.unrecognized] == nil)
        #expect(sidebar.unrecognizedFavoritesContainers == 2)
    }

    private func spaceContents(_ sidebar: ArcSidebar) -> (pinned: [ArcNode], unpinned: [ArcNode], missing: Bool) {
        (sidebar.spaces[0].pinned, sidebar.spaces[0].unpinned, sidebar.spaces[0].contentsMissing)
    }

    private var pinnedAndUnpinnedItems: [String] {
        [
            arcSpaceContainerJSON("P", children: ["TP"]),
            arcTabJSON("TP", parent: "P", url: "https://p.example.com/"),
            arcSpaceContainerJSON("U", children: ["TU"]),
            arcTabJSON("TU", parent: "U", url: "https://u.example.com/"),
        ]
    }

    private let legacyIDs = #""containerIDs":["unpinned","U","pinned","P"]"#

    @Test func emptyNewContainerIDsFallBackToLegacy() throws {
        let space = arcSpaceJSON("S", #""title":"S","profile":{"default":true},"newContainerIDs":[],\#(legacyIDs)"#)
        let contents = spaceContents(try ArcSidebarParser.parse(arcSidebarData(items: pinnedAndUnpinnedItems, spaces: [space])))
        #expect(contents.pinned == [.tab(ArcTab(url: "https://p.example.com/", title: ""))])
        #expect(contents.unpinned == [.tab(ArcTab(url: "https://u.example.com/", title: ""))])
        #expect(!contents.missing)
    }

    @Test func eachKindFallsBackIndependently() throws {
        let space = arcSpaceJSON("S", #""title":"S","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"P"],\#(legacyIDs)"#)
        let contents = spaceContents(try ArcSidebarParser.parse(arcSidebarData(items: pinnedAndUnpinnedItems, spaces: [space])))
        #expect(contents.pinned.count == 1)
        #expect(contents.unpinned == [.tab(ArcTab(url: "https://u.example.com/", title: ""))])
        #expect(!contents.missing)
    }

    @Test func spaceWithoutResolvableContainersIsKeptAndFlagged() throws {
        let pinnedAbsent = arcSpaceJSON("S", #""title":"S","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"GONE"]"#)
        let noIDs = arcSpaceJSON("S", #""title":"S","profile":{"default":true},"newContainerIDs":[]"#)
        let unpinnedAbsent = arcSpaceJSON("S", #""title":"S","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"P",{"unpinned":{}},"GONE"]"#)
        for space in [pinnedAbsent, noIDs, unpinnedAbsent] {
            let sidebar = try ArcSidebarParser.parse(arcSidebarData(items: pinnedAndUnpinnedItems, spaces: [space]))
            #expect(sidebar.spaces.count == 1, "\(space)")
            #expect(sidebar.spaces[0].contentsMissing, "\(space)")
        }
    }

    @Test func unsupportedItemKeepsItsChildren() throws {
        let items = [
            arcSpaceContainerJSON("P", children: ["M"]),
            arcItemJSON("M", parent: "P", children: ["T1", "T2"], title: "Odd", data: #"{"mystery":{}}"#),
            arcTabJSON("T1", parent: "M", url: "https://one.example.com/"),
            arcTabJSON("T2", parent: "M", url: "https://two.example.com/"),
        ]
        let space = arcSpaceJSON("S", #""title":"S","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"P"]"#)
        let sidebar = try ArcSidebarParser.parse(arcSidebarData(items: items, spaces: [space]))
        #expect(sidebar.spaces[0].pinned == [.unsupported(kind: "mystery", title: "Odd", children: [
            .tab(ArcTab(url: "https://one.example.com/", title: "")),
            .tab(ArcTab(url: "https://two.example.com/", title: "")),
        ])])
    }

    @Test func missingProfileIsDefaultAndUnknownIsUnrecognized() throws {
        let ids = #""newContainerIDs":[{"pinned":{}},"P"]"#
        let spaces = [
            arcSpaceJSON("S1", #""title":"A",\#(ids)"#),
            arcSpaceJSON("S2", #""title":"B","profile":{"something":{}},\#(ids)"#),
            arcSpaceJSON("S3", #""title":"C","profile":{"default":true},\#(ids)"#),
        ]
        let sidebar = try ArcSidebarParser.parse(arcSidebarData(items: pinnedAndUnpinnedItems, spaces: spaces))
        #expect(sidebar.spaces.map(\.profile) == [.default, .unrecognized, .default])
    }

    @Test func emptyTitleAndEmojiAreNil() throws {
        let space = arcSpaceJSON("S", #""title":"","profile":{"default":true},"customInfo":{"iconType":{"emoji_v2":""}},"newContainerIDs":[{"pinned":{}},"P"]"#)
        let sidebar = try ArcSidebarParser.parse(arcSidebarData(items: pinnedAndUnpinnedItems, spaces: [space]))
        #expect(sidebar.spaces[0].title == nil)
        #expect(sidebar.spaces[0].emoji == nil)
    }

    @Test func pinnedCopyWinsOverEarlierSpacesUnpinnedDuplicate() throws {
        let items = [
            arcSpaceContainerJSON("A-PIN", children: []),
            arcSpaceContainerJSON("A-UNP", children: ["T"]),
            arcSpaceContainerJSON("B-PIN", children: ["T"]),
            arcSpaceContainerJSON("B-UNP", children: []),
            arcTabJSON("T", parent: "B-PIN", url: "https://shared.example.com/"),
        ]
        let spaces = [
            arcSpaceJSON("SA", #""title":"A","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"A-PIN",{"unpinned":{}},"A-UNP"]"#),
            arcSpaceJSON("SB", #""title":"B","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"B-PIN",{"unpinned":{}},"B-UNP"]"#),
        ]
        let sidebar = try ArcSidebarParser.parse(arcSidebarData(items: items, spaces: spaces))
        #expect(sidebar.spaces[0].unpinned.isEmpty)
        #expect(sidebar.spaces[1].pinned == [.tab(ArcTab(url: "https://shared.example.com/", title: ""))])
        #expect(sidebar.duplicateItems == 1)
    }

    @Test func favoriteCopyWinsOverUnpinnedDuplicate() throws {
        let items = [
            arcSpaceContainerJSON("A-PIN", children: []),
            arcSpaceContainerJSON("A-UNP", children: ["T"]),
            arcFavoritesJSON("FAV", children: ["T"], marker: defaultMarker),
            arcTabJSON("T", parent: "FAV", url: "https://shared.example.com/"),
        ]
        let space = arcSpaceJSON("SA", #""title":"A","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"A-PIN",{"unpinned":{}},"A-UNP"]"#)
        let sidebar = try ArcSidebarParser.parse(arcSidebarData(items: items, spaces: [space]))
        #expect(sidebar.spaces[0].unpinned.isEmpty)
        #expect(sidebar.favorites[.default]?.count == 1)
    }

    @Test func maximumDepthIsSixtyFour() {
        #expect(ArcSidebarParser.maximumDepth == 64)
    }

    @Test func deeplyNestedJSONArrayDoesNotCrash() async throws {
        // 511 levels: inside Foundation's own 512 limit, so only our decoding stack is exercised.
        let nested = String(repeating: "[", count: 511) + String(repeating: "]", count: 511)
        let spaceFields = #""title":"S","profile":{"default":true},"newContainerIDs":[{"pinned":{}},"P"],"junk":\#(nested)"#
        let inSidebar = arcSidebarData(
            items: [arcSpaceContainerJSON("P", children: [])], spaces: [arcSpaceJSON("S", spaceFields)])
        let whole = Data(nested.utf8)
        let outcomes = await Task.detached { () -> [Bool] in
            [inSidebar, whole].map { data in
                do { _ = try ArcSidebarParser.parse(data); return true } catch is ArcImportError { return true } catch { return false }
            }
        }.value
        #expect(outcomes == [true, true])
    }

    @Test func emptyUnrecognizedFavoritesContainerIsNotCounted() throws {
        let items = [arcFavoritesJSON("FAV", children: [], marker: #"{"something":{}}"#)]
        let sidebar = try ArcSidebarParser.parse(arcSidebarData(items: items, spaces: []))
        #expect(sidebar.unrecognizedFavoritesContainers == 0)
    }
}
