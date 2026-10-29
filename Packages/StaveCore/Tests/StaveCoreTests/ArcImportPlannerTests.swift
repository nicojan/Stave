import Foundation
import Testing
@testable import StaveCore

struct ArcImportPlannerTests {
    private func plan(_ fixture: String, includeUnpinned: Bool = false, names: [String: String] = [:]) throws -> ArcImportPlan {
        let sidebar = try ArcSidebarParser.parse(try arcFixture(fixture))
        return ArcImportPlanner.plan(sidebar, options: ArcImportOptions(includeUnpinnedTabs: includeUnpinned), profileNames: names)
    }

    private func tab(_ url: String, _ title: String) -> PlannedTab { PlannedTab(url: url, title: title) }

    private func allTabs(_ pinned: [PlannedPinned]) -> [PlannedTab] {
        pinned.flatMap { node -> [PlannedTab] in
            switch node {
            case .tab(let t): return [t]
            case .folder(_, let children): return allTabs(children)
            }
        }
    }

    @Test func basicPlan() throws {
        let plan = try plan("basic")
        #expect(plan.profiles.count == 1)
        let profile = plan.profiles[0]
        #expect(profile.target == .existingDefault)
        #expect(profile.workspaces.map(\.name) == ["Work", "Space 1"])
        #expect(profile.workspaces[0].icon == "💼")
        #expect(profile.workspaces[0].colorHex == "#5C6BF2")
        #expect(profile.workspaces[1].icon == ArcImportPlanner.defaultIcon)
        #expect(profile.workspaces[1].colorHex == ArcImportPlanner.defaultColorHex)
        #expect(profile.workspaces[0].pinned == [
            .folder(title: "Docs", children: [
                .tab(tab("https://spec.example.com/draft", "Draft Spec")),
                .tab(tab("https://notes.example.com/daily", "Daily Notes")),
            ]),
            .tab(tab("https://board.example.com/team", "My Board")),
        ])
        #expect(profile.workspaces[0].regular.isEmpty)
        #expect(plan.skipped.contains(.unpinnedTabs(space: "Work", count: 2)))
        #expect(profile.essentials.count == 2)
    }

    @Test func includeUnpinnedTabsCreatesRegularTabs() throws {
        let plan = try plan("basic", includeUnpinned: true)
        #expect(plan.profiles[0].workspaces[0].regular == [
            tab("https://mail.example.com/inbox", "Inbox"),
            tab("https://calendar.example.com/week", "Week View"),
        ])
        let hasUnpinnedEntry = plan.skipped.contains { if case .unpinnedTabs = $0 { return true } else { return false } }
        #expect(!hasUnpinnedEntry)
    }

    @Test func unpinnedOffReportsOnlyTheCount() throws {
        let plan = try plan("edge-cases")
        #expect(plan.skipped.contains(.unpinnedTabs(space: "Acme", count: 3)))
        // Unpinned split must not be reported when unpinned import is off: only the pinned split is.
        let splits = plan.flattened.filter { $0 == .splitView(space: "Acme", tabCount: 2) }
        #expect(splits.count == 1)
    }

    @Test func unpinnedOnFlattensSplitsAndReportsThem() throws {
        let plan = try plan("edge-cases", includeUnpinned: true, names: ["Profile 1": "Client Work"])
        let acme = try #require(plan.profiles.first { $0.target == .new(name: "Client Work") })
        #expect(acme.workspaces[0].regular == [
            tab("https://unpinned-a.example.com/", "Unpinned A"),
            tab("https://unpinned-b.example.com/", "Unpinned B"),
            tab("https://unpinned.example.net/", "Unpinned"),
        ])
        let splits = plan.flattened.filter { $0 == .splitView(space: "Acme", tabCount: 2) }
        #expect(splits.count == 2)
    }

    @Test func deepFolderFlattensIntoLevelTwo() throws {
        let plan = try plan("edge-cases", names: ["Profile 1": "Client Work"])
        let acme = try #require(plan.profiles.first { $0.target == .new(name: "Client Work") }?.workspaces.first)
        #expect(acme.pinned.first == .folder(title: "Level 1", children: [
            .folder(title: "Level 2", children: [.tab(tab("https://deep.example.com/", "Deep"))]),
        ]))
        #expect(plan.flattened.contains(.folderTooDeep(space: "Acme", folder: "Level 3")))
    }

    @Test func splitViewBecomesTabsInPlace() throws {
        let plan = try plan("edge-cases", names: ["Profile 1": "Client Work"])
        let acme = try #require(plan.profiles.first { $0.target == .new(name: "Client Work") }?.workspaces.first)
        let a = PlannedPinned.tab(tab("https://split-a.example.org/", "Split A"))
        let b = PlannedPinned.tab(tab("https://split-b.example.org/", "Split B"))
        let index = try #require(acme.pinned.firstIndex(of: a))
        #expect(acme.pinned[index + 1] == b)
        #expect(plan.flattened.contains(.splitView(space: "Acme", tabCount: 2)))
    }

    @Test func nonWebURLsAreSkipped() throws {
        let plan = try plan("edge-cases")
        for profile in plan.profiles {
            for workspace in profile.workspaces {
                for t in allTabs(workspace.pinned) + workspace.regular {
                    let scheme = URL(string: t.url)?.scheme?.lowercased()
                    #expect(scheme == "http" || scheme == "https")
                }
            }
            for t in profile.essentials {
                let scheme = URL(string: t.url)?.scheme?.lowercased()
                #expect(scheme == "http" || scheme == "https")
            }
        }
        let schemes = plan.skipped.compactMap { entry -> String? in
            if case .nonWebURL(_, _, let scheme) = entry { return scheme }
            return nil
        }.sorted()
        #expect(schemes == ["", "", "file", "javascript", "javascript"])
    }

    @Test func titlesAreKeptVerbatim() throws {
        let plan = try plan("edge-cases", names: ["Profile 1": "Client Work"])
        let acme = try #require(plan.profiles.first { $0.target == .new(name: "Client Work") }?.workspaces.first)
        let long = try #require(allTabs(acme.pinned).first { $0.url == "https://long.example.net/" })
        #expect(long.title.hasPrefix("東京🚀Ünïcødé"))
        #expect(long.title.count == 300)
        #expect(Array(long.title.utf8).count > 300)
        // Compare with the parsed source bytes.
        let sidebar = try ArcSidebarParser.parse(try arcFixture("edge-cases"))
        let source = sidebar.spaces[0].pinned.compactMap { node -> String? in
            if case .tab(let t) = node, t.url == "https://long.example.net/" { return t.title }
            return nil
        }
        #expect(source == [long.title])
    }

    @Test func emptyTitleStaysEmpty() {
        let sidebar = ArcSidebar(
            spaces: [ArcSpace(title: "S", profile: .default, emoji: nil, colorHex: nil,
                              pinned: [.tab(ArcTab(url: "https://a.example.com/", title: ""))], unpinned: [])],
            favorites: [:], duplicateItems: 0)
        let plan = ArcImportPlanner.plan(sidebar, options: ArcImportOptions(), profileNames: [:])
        #expect(plan.profiles[0].workspaces[0].pinned == [.tab(tab("https://a.example.com/", ""))])
    }

    @Test func profilesNamedFromLocalState() throws {
        let named = try plan("edge-cases", names: ["Profile 1": "Client Work"])
        #expect(named.profiles.map(\.target) == [.existingDefault, .new(name: "Client Work")])
        let def = named.profiles[0]
        #expect(def.workspaces.map(\.name) == ["Odd"])
        #expect(named.skipped.contains(.unrecognizedProfile(space: "Odd")))
        let client = named.profiles[1]
        #expect(client.workspaces.map(\.name) == ["Acme"])
        #expect(client.essentials.count == 2)
        #expect(client.essentials == [
            tab("https://fav-inner.example.com/", "Fav Inner"),
            tab("https://fav-plain.example.org/", "Fav Plain"),
        ])
        #expect(named.flattened.contains(.favoritesFolder(folder: "Fav Folder")))

        let unnamed = try plan("edge-cases", names: [:])
        #expect(unnamed.profiles.map(\.target) == [.existingDefault, .new(name: "Profile 1")])
        for p in [named, unnamed] {
            #expect(!p.profiles.contains { $0.target == .new(name: "Profile 9") })
        }
    }

    @Test func unsupportedAndDuplicatesReported() throws {
        let plan = try plan("edge-cases")
        #expect(plan.skipped.contains(.unsupportedItem(space: "Acme", kind: "easel", title: "Sketch")))
        #expect(plan.skipped.contains(.unsupportedItem(space: "Acme", kind: "welcomeToArc", title: nil)))
        #expect(plan.skipped.contains(.duplicateItem(count: 2)))
        #expect(plan.skipped.last == .duplicateItem(count: 2))
    }

    @Test func favoritesNonWebAndUnsupportedCarryNoSpace() {
        let sidebar = ArcSidebar(
            spaces: [],
            favorites: [.default: [
                .tab(ArcTab(url: "file:///x", title: "F")),
                .unsupported(kind: "easel", title: "E"),
                .split([ArcTab(url: "https://a.example.com/", title: "A"), ArcTab(url: "https://b.example.com/", title: "B")]),
            ]],
            duplicateItems: 0)
        let plan = ArcImportPlanner.plan(sidebar, options: ArcImportOptions(), profileNames: [:])
        #expect(plan.skipped.contains(.nonWebURL(space: nil, title: "F", scheme: "file")))
        #expect(plan.skipped.contains(.unsupportedItem(space: nil, kind: "easel", title: "E")))
        #expect(plan.flattened.contains(.splitView(space: nil, tabCount: 2)))
        #expect(plan.profiles[0].essentials.count == 2)
    }
}
