import Foundation
import Testing
@testable import StaveCore

struct SampleOrganizationTests {
    private func allTabs(_ items: [PinnedItem]) -> [Tab] {
        items.flatMap { item -> [Tab] in
            switch item {
            case .tab(let tab): return [tab]
            case .folder(_, let children): return allTabs(children)
            }
        }
    }

    @Test func seedFillsEmptyStore() throws {
        let (store, _, _) = try makeTempStore()
        #expect(try SampleOrganization.seed(into: store) == true)

        let profile = try #require(try store.profiles().first)
        let workspaces = try store.workspaces(profileID: profile.id)
        #expect(workspaces.map(\.name) == ["Home", "Work"])
        let home = workspaces[0]
        let work = workspaces[1]
        #expect(work.icon == "💼")
        #expect(work.colorHex == "#3478F6")

        let essentials = try store.essentials(profileID: profile.id)
        #expect(essentials.count == 3)

        let homeSnapshot = try store.sidebarSnapshot(workspaceID: home.id)
        #expect(homeSnapshot.pinned.count == 3)
        guard case .folder(let reading, let readingChildren) = homeSnapshot.pinned[0] else {
            Issue.record("first pinned item is not the Reading folder"); return
        }
        #expect(reading.title == "Reading")
        #expect(readingChildren.count == 3)
        let laterChildren = readingChildren.compactMap { item -> [PinnedItem]? in
            if case .folder(let f, let kids) = item, f.title == "Later" { return kids }
            return nil
        }
        #expect(laterChildren.count == 1)
        #expect(laterChildren.first?.count == 2)
        let readingTabs = readingChildren.filter { if case .tab = $0 { return true } else { return false } }
        #expect(readingTabs.count == 2)
        guard case .tab = homeSnapshot.pinned[1], case .tab = homeSnapshot.pinned[2] else {
            Issue.record("root pinned items are not tabs"); return
        }
        let pinnedTabs = allTabs(homeSnapshot.pinned)
        #expect(pinnedTabs.count == 6)
        #expect(pinnedTabs.filter(store.isDrifted).count == 1)
        #expect(allTabs(readingChildren.filter { if case .tab = $0 { return true } else { return false } }).filter(store.isDrifted).count == 1)
        #expect(homeSnapshot.regular.count == 4)
        let containers = try store.containers(profileID: profile.id)
        #expect(containers.map(\.name) == ["Work Google"])
        #expect(containers.first?.colorHex == "#34C759")
        #expect(homeSnapshot.regular.filter { $0.containerID == containers.first?.id }.count == 1)

        let workSnapshot = try store.sidebarSnapshot(workspaceID: work.id)
        #expect(allTabs(workSnapshot.pinned).count == 1)
        #expect(workSnapshot.regular.count == 2)

        let archived = try store.archivedTabs(profileID: profile.id)
        #expect(archived.count == 2)

        let urls = essentials.map(\.url) + pinnedTabs.flatMap { [$0.url, $0.pinnedURL ?? $0.url] }
            + homeSnapshot.regular.map(\.url) + allTabs(workSnapshot.pinned).map(\.url)
            + workSnapshot.regular.map(\.url) + archived.map(\.url)
        for url in urls {
            let host = try #require(URL(string: url)?.host)
            #expect(["example.com", "example.org", "example.net"].contains { host == $0 || host.hasSuffix("." + $0) }, "\(url)")
        }

        let titles = essentials.map(\.title) + pinnedTabs.map(\.title) + homeSnapshot.regular.map(\.title)
            + workSnapshot.regular.map(\.title) + archived.map(\.title)
        #expect(titles.contains { $0.unicodeScalars.contains { $0.value >= 0x3040 && $0.value <= 0x30FF } })
        #expect(titles.contains { $0.count == 200 })
    }

    @Test func seedLeavesUsedStoreAlone() throws {
        let (store, _, _) = try makeTempStore()
        let profile = try store.ensureDefaultProfile()
        let ws = try #require(try store.workspaces(profileID: profile.id).first)
        _ = try store.openTab(url: "https://example.com/", title: "One", workspaceID: ws.id, origin: .commandBar, containerID: nil, edge: .top)
        #expect(try SampleOrganization.seed(into: store) == false)
        #expect(try store.regularTabs(workspaceID: ws.id).count == 1)
        #expect(try store.workspaces(profileID: profile.id).count == 1)
        #expect(try store.essentials(profileID: profile.id).isEmpty)
    }
}
