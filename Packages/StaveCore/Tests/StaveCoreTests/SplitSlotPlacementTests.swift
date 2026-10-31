import Foundation
import GRDB
import Testing
@testable import StaveCore

struct SplitSlotPlacementTests {
    /// A link opened from the second tab of a split slot lands directly below that slot, as it did when every tab was looked up by id.
    @Test func openerInsideSplitSlotPlacesBelowItsSlot() throws {
        let (store, database, _) = try makeTempStore()
        let profile = try store.ensureDefaultProfile()
        let workspace = try #require(try store.workspaces(profileID: profile.id).first)
        let split = Slot(profileID: profile.id, workspaceID: workspace.id, section: .regular, kind: .split, sortIndex: 0)
        let after = Slot(profileID: profile.id, workspaceID: workspace.id, section: .regular, sortIndex: 10)
        let first = Tab(slotID: split.id, url: "https://a.example.com/", title: "A")
        let second = Tab(slotID: split.id, url: "https://b.example.com/", title: "B")
        let later = Tab(slotID: after.id, url: "https://c.example.com/", title: "C")
        try database.writer.write { db in
            try split.insert(db); try after.insert(db)
            try first.insert(db); try second.insert(db); try later.insert(db)
        }

        let opened = try store.openTab(
            url: "https://d.example.com/", title: "D", workspaceID: workspace.id,
            origin: .link(openerTabID: second.id), containerID: nil, edge: .bottom
        )

        #expect(try store.regularTabs(workspaceID: workspace.id).map(\.id) == [first.id, opened.id, later.id])
    }

    /// Equal sort indices only keep insertion order if every ordering query ends in `rowid`, so the SQL itself is checked.
    @Test func profileAndWorkspaceQueriesBreakTiesOnRowid() throws {
        let statements = StatementLog()
        let (store, database, _) = try makeTempStore()
        let profile = try store.createProfile(name: "P")
        // Sequential reads reuse the pool's idle reader connection, so a trace installed on it sees the store's own reads.
        try database.writer.read { db in db.trace { statements.append($0.description) } }

        statements.reset()
        _ = try store.profiles()
        _ = try store.workspaces(profileID: profile.id)
        let ordered = statements.all.filter { $0.contains("ORDER BY") }

        #expect(ordered.count == 2)
        for sql in ordered { #expect(sql.contains("\"rowid\"") && sql.hasSuffix("\"rowid\"")) }
    }
}

final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ sql: String) { lock.lock(); items.append(sql); lock.unlock() }
    func reset() { lock.lock(); items = []; lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
