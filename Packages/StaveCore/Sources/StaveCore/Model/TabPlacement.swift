import Foundation

/// Where a new tab was requested from.
public enum NewTabOrigin: Sendable, Equatable { case commandBar, link(openerTabID: UUID), externalApp }

/// Which end of the regular list new non-link tabs go to.
public enum NewTabEdge: String, Codable, Sendable { case top, bottom }

/// Pure placement rules for new regular tabs. Returns a sort index only; renormalizing crowded indices is the store's job.
public enum TabPlacement {
    /// - Parameter regularIndices: the workspace's regular tab IDs mapped to their sort indices.
    public static func sortIndex(
        origin: NewTabOrigin,
        regularIndices: [UUID: Double],
        edge: NewTabEdge
    ) -> Double {
        if case .link(let openerID) = origin, let openerIndex = regularIndices[openerID] {
            return indexDirectlyBelow(openerIndex, in: regularIndices)
        }
        return indexAtEdge(edge, in: regularIndices)
    }

    private static func indexAtEdge(_ edge: NewTabEdge, in indices: [UUID: Double]) -> Double {
        switch edge {
        case .top:
            return indices.values.min().map { $0 - 1 } ?? 0
        case .bottom:
            return indices.values.max().map { $0 + 1 } ?? 0
        }
    }

    private static func indexDirectlyBelow(_ openerIndex: Double, in indices: [UUID: Double]) -> Double {
        guard let next = indices.values.filter({ $0 > openerIndex }).min() else {
            return openerIndex + 1
        }
        return (openerIndex + next) / 2
    }
}
