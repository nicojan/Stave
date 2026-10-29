import Foundation

/// Turns the bytes of Arc's `StorableSidebar.json` into an `ArcSidebar`.
public enum ArcSidebarParser {
    public static let maximumFileSize = 64 * 1024 * 1024
    public static let maximumDepth = 64

    public static func parse(_ data: Data) throws -> ArcSidebar {
        guard data.count <= maximumFileSize else { throw ArcImportError.fileTooLarge }
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ArcImportError.notJSON
        }
        guard let container = findContainer(in: root) else { throw ArcImportError.noSidebar }
        let items = itemsByID(container["items"]?.array ?? [])
        let spaces = try (container["spaces"]?.array ?? []).compactMap { value -> ArcSpace? in
            guard let space = value.object else { return nil }
            return try parseSpace(space, items: items)
        }
        let favorites = try parseFavorites(items: items)
        return ArcSidebar(spaces: spaces, favorites: favorites, duplicateItems: 0)
    }

    // MARK: - Locating data

    private static func findContainer(in root: JSONValue) -> [String: JSONValue]? {
        let containers = root["sidebar"]?["containers"]?.array ?? []
        return containers.lazy
            .compactMap(\.object)
            .first { $0["spaces"] != nil && $0["items"] != nil }
    }

    private static func itemsByID(_ list: [JSONValue]) -> [String: [String: JSONValue]] {
        var result: [String: [String: JSONValue]] = [:]
        var pendingID: String?
        for element in list {
            if let id = element.string {
                pendingID = id
            } else if let object = element.object {
                if let id = object["id"]?.string ?? pendingID { result[id] = object }
                pendingID = nil
            }
        }
        return result
    }

    // MARK: - Spaces

    private static func parseSpace(
        _ space: [String: JSONValue],
        items: [String: [String: JSONValue]]
    ) throws -> ArcSpace {
        let containers = containerIDs(space["newContainerIDs"]?.array ?? [])
        let icon = space["customInfo"]?["iconType"]
        let midTone = space["customInfo"]?["windowTheme"]?["primaryColorPalette"]?["midTone"]
        return ArcSpace(
            title: space["title"]?.string,
            profile: profileKey(space["profile"]),
            emoji: icon?["emoji_v2"]?.string,
            colorHex: midTone.flatMap(hexColor),
            pinned: try nodes(inContainer: containers.pinned, items: items),
            unpinned: try nodes(inContainer: containers.unpinned, items: items)
        )
    }

    /// `newContainerIDs` alternates a marker object with the container id that follows it.
    private static func containerIDs(_ list: [JSONValue]) -> (pinned: String?, unpinned: String?) {
        var pinned: String?
        var unpinned: String?
        for (index, element) in list.enumerated() {
            guard let marker = element.object, index + 1 < list.count,
                  let id = list[index + 1].string else { continue }
            if marker["pinned"] != nil { pinned = id }
            if marker["unpinned"] != nil { unpinned = id }
        }
        return (pinned, unpinned)
    }

    private static func profileKey(_ marker: JSONValue?) -> ArcProfileKey {
        if case .bool(true)? = marker?["default"] { return .default }
        return .unrecognized
    }

    private static func hexColor(_ midTone: JSONValue) -> String? {
        let channels = ["red", "green", "blue"].compactMap { midTone[$0]?.number }
        guard channels.count == 3 else { return nil }
        let bytes = channels.map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    // MARK: - Favorites

    private static func parseFavorites(
        items: [String: [String: JSONValue]]
    ) throws -> [ArcProfileKey: [ArcNode]] {
        var result: [ArcProfileKey: [ArcNode]] = [:]
        for (id, item) in items.sorted(by: { $0.key < $1.key }) where isRoot(item) {
            guard let marker = item["data"]?["itemContainer"]?["containerType"]?["topApps"]?["_0"] else { continue }
            result[profileKey(marker)] = try nodes(inContainer: id, items: items)
        }
        return result
    }

    private static func isRoot(_ item: [String: JSONValue]) -> Bool {
        item["parentID"] == nil || item["parentID"] == .null
    }

    // MARK: - Item trees

    private static func nodes(
        inContainer id: String?,
        items: [String: [String: JSONValue]]
    ) throws -> [ArcNode] {
        guard let id, let container = items[id] else { return [] }
        return try children(of: container, items: items, depth: 1)
    }

    private static func children(
        of item: [String: JSONValue],
        items: [String: [String: JSONValue]],
        depth: Int
    ) throws -> [ArcNode] {
        guard depth <= maximumDepth else { throw ArcImportError.tooDeep }
        return try (item["childrenIds"]?.array ?? []).compactMap { childID in
            guard let id = childID.string, let child = items[id] else { return nil }
            return try node(child, items: items, depth: depth)
        }
    }

    private static func node(
        _ item: [String: JSONValue],
        items: [String: [String: JSONValue]],
        depth: Int
    ) throws -> ArcNode {
        let data = item["data"]?.object ?? [:]
        if let tab = data["tab"] {
            return .tab(arcTab(item, tab))
        }
        if data["list"] != nil {
            let kids = try children(of: item, items: items, depth: depth + 1)
            return .folder(title: item["title"]?.string ?? "", children: kids)
        }
        if data["splitView"] != nil {
            let kids = try children(of: item, items: items, depth: depth + 1)
            let tabs = kids.compactMap { node -> ArcTab? in
                if case .tab(let tab) = node { return tab }
                return nil
            }
            return .split(tabs)
        }
        return .unsupported(kind: data.keys.sorted().first ?? "", title: item["title"]?.string)
    }

    private static func arcTab(_ item: [String: JSONValue], _ tab: JSONValue) -> ArcTab {
        ArcTab(
            url: tab["savedURL"]?.string ?? "",
            title: item["title"]?.string ?? tab["savedTitle"]?.string ?? ""
        )
    }
}
