import Foundation
import Testing
@testable import StaveCore

struct TabPlacementTests {
    private let a = UUID()
    private let b = UUID()

    private func indices() -> [UUID: Double] { [a: 1, b: 2] }

    @Test func emptyWorkspaceIsZero() {
        for origin in [NewTabOrigin.commandBar, .externalApp, .link(openerTabID: a)] {
            for edge in [NewTabEdge.top, .bottom] {
                #expect(TabPlacement.sortIndex(origin: origin, regularIndices: [:], edge: edge) == 0)
            }
        }
    }

    @Test func commandBarTopGoesAboveFirst() {
        let result = TabPlacement.sortIndex(origin: .commandBar, regularIndices: indices(), edge: .top)
        #expect(result < 1)
    }

    @Test func commandBarBottomGoesBelowLast() {
        let result = TabPlacement.sortIndex(origin: .commandBar, regularIndices: indices(), edge: .bottom)
        #expect(result > 2)
    }

    @Test func externalAppBottomGoesBelowLast() {
        let result = TabPlacement.sortIndex(origin: .externalApp, regularIndices: indices(), edge: .bottom)
        #expect(result > 2)
    }

    @Test func externalAppTopGoesAboveFirst() {
        let result = TabPlacement.sortIndex(origin: .externalApp, regularIndices: indices(), edge: .top)
        #expect(result < 1)
    }

    @Test func linkGoesDirectlyBelowOpener() {
        let result = TabPlacement.sortIndex(origin: .link(openerTabID: a), regularIndices: indices(), edge: .top)
        #expect(result > 1 && result < 2)
    }

    @Test func linkFromLastTabGoesBelowIt() {
        let result = TabPlacement.sortIndex(origin: .link(openerTabID: b), regularIndices: indices(), edge: .top)
        #expect(result > 2)
    }

    @Test func linkWithUnknownOpenerFallsBackToEdge() {
        let unknown = UUID()
        let top = TabPlacement.sortIndex(origin: .link(openerTabID: unknown), regularIndices: indices(), edge: .top)
        let bottom = TabPlacement.sortIndex(origin: .link(openerTabID: unknown), regularIndices: indices(), edge: .bottom)
        #expect(top < 1)
        #expect(bottom > 2)
    }

    @Test func sixtyInsertionsBelowSameOpenerStayDistinctAndOrdered() {
        // Opener sits at 0: doubles near 0 keep halving distinctly (~1074 times), while near 1 they collapse after ~52
        // (ulp ~2.2e-16), which is why Task 5 must renormalize crowded indices.
        var map: [UUID: Double] = [a: 0, b: 1]
        var inserted: [Double] = []
        for _ in 0..<60 {
            let value = TabPlacement.sortIndex(origin: .link(openerTabID: a), regularIndices: map, edge: .top)
            map[UUID()] = value
            inserted.append(value)
        }
        #expect(Set(inserted).count == 60)
        // Each new tab lands directly below the opener, so it sorts above the previous insertion.
        for (earlier, later) in zip(inserted, inserted.dropFirst()) {
            #expect(later < earlier)
            #expect(later > 0)
        }
        #expect(Set(map.values).count == map.count)
    }
}
