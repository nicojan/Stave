import Foundation

public enum SidebarItemID: Hashable, Sendable { case tab(UUID), folder(UUID) }

public struct SidebarRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case pinnedTab(drifted: Bool), folder(isOpen: Bool, childCount: Int), regularTab }
    public var id: SidebarItemID
    public var kind: Kind
    /// 0 at the root, 1 inside a folder, 2 inside a sub-folder.
    public var depth: Int
    public var parentFolderID: UUID?
    /// `DisplayText.title`.
    public var title: String
    public var containerColorHex: String?
    public var accessibilityLabel: String

    public init(id: SidebarItemID, kind: Kind, depth: Int, parentFolderID: UUID?, title: String, containerColorHex: String?, accessibilityLabel: String) {
        self.id = id; self.kind = kind; self.depth = depth; self.parentFolderID = parentFolderID
        self.title = title; self.containerColorHex = containerColorHex; self.accessibilityLabel = accessibilityLabel
    }
}

public enum SidebarRows {
    /// The pinned tree (a folder, then its children when open, sub-folders likewise), then the regular tabs. Essentials are not rows.
    public static func build(_ snapshot: SidebarSnapshot, containers: [Container]) -> [SidebarRow] {
        let byID = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = rows(for: snapshot.pinned, depth: 0, parent: nil, containers: byID)
        let regular = snapshot.regular.map { tab -> SidebarRow in
            let container = tab.containerID.flatMap { byID[$0] }
            let title = DisplayText.title(for: tab)
            return SidebarRow(
                id: .tab(tab.id), kind: .regularTab, depth: 0, parentFolderID: nil, title: title,
                containerColorHex: container?.colorHex,
                accessibilityLabel: SidebarLabels.regularTab(title: title, containerName: container?.name)
            )
        }
        return pinned + regular
    }

    private static func rows(for items: [PinnedItem], depth: Int, parent: UUID?, containers: [UUID: Container]) -> [SidebarRow] {
        items.flatMap { item -> [SidebarRow] in
            switch item {
            case .tab(let tab):
                let drifted = tab.isDrifted
                let title = DisplayText.title(for: tab)
                return [SidebarRow(
                    id: .tab(tab.id), kind: .pinnedTab(drifted: drifted), depth: depth, parentFolderID: parent, title: title,
                    containerColorHex: tab.containerID.flatMap { containers[$0] }?.colorHex,
                    accessibilityLabel: SidebarLabels.pinnedTab(title: title, drifted: drifted)
                )]
            case .folder(let folder, let children):
                let head = SidebarRow(
                    id: .folder(folder.id), kind: .folder(isOpen: folder.isOpen, childCount: children.count), depth: depth,
                    parentFolderID: parent, title: folder.title, containerColorHex: nil,
                    accessibilityLabel: SidebarLabels.folder(title: folder.title, isOpen: folder.isOpen, childCount: children.count)
                )
                guard folder.isOpen else { return [head] }
                return [head] + rows(for: children, depth: depth + 1, parent: folder.id, containers: containers)
            }
        }
    }
}

/// VoiceOver labels, one per row form. The sidebar and the by-hand VoiceOver check both read these.
public enum SidebarLabels {
    public static func essential(title: String) -> String { "\(title), Essential" }

    public static func pinnedTab(title: String, drifted: Bool) -> String {
        drifted ? "\(title), pinned tab, away from its pinned page" : "\(title), pinned tab"
    }

    public static func folder(title: String, isOpen: Bool, childCount: Int) -> String {
        "\(title), folder, \(isOpen ? "open" : "closed"), \(childCount) \(childCount == 1 ? "item" : "items")"
    }

    public static func regularTab(title: String, containerName: String?) -> String {
        guard let containerName else { return "\(title), tab" }
        return "\(title), tab, in \(containerName)"
    }

    public static func workspace(name: String, position: Int, count: Int, isCurrent: Bool) -> String {
        "\(name), workspace \(position) of \(count)" + (isCurrent ? ", current" : "")
    }
}
