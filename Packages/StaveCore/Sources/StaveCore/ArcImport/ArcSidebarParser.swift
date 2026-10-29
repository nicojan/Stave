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
        var walk = Walk(items: items)
        let spaces = try (container["spaces"]?.array ?? []).compactMap { value -> ArcSpace? in
            guard let space = value.object else { return nil }
            return try parseSpace(space, walk: &walk)
        }
        let favorites = try parseFavorites(
            listed: (container["topAppsContainerIDs"]?.array ?? []).compactMap(\.string),
            walk: &walk
        )
        return ArcSidebar(spaces: spaces, favorites: favorites, duplicateItems: walk.duplicates)
    }

    /// State shared by the whole parse: one visited set keeps the walk linear in item count.
    private struct Walk {
        let items: [String: [String: JSONValue]]
        var visited: Set<String> = []
        var duplicates = 0
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
        walk: inout Walk
    ) throws -> ArcSpace {
        let list = space["newContainerIDs"]?.array ?? space["containerIDs"]?.array ?? []
        let containers = containerIDs(list)
        let icon = space["customInfo"]?["iconType"]
        let midTone = space["customInfo"]?["windowTheme"]?["primaryColorPalette"]?["midTone"]
        return ArcSpace(
            title: space["title"]?.string,
            profile: profileKey(space["profile"]),
            emoji: icon?["emoji_v2"]?.string,
            colorHex: midTone.flatMap(hexColor),
            pinned: try nodes(inContainer: containers.pinned, walk: &walk),
            unpinned: try nodes(inContainer: containers.unpinned, walk: &walk)
        )
    }

    /// A marker (`{"pinned": …}`, `{"unpinned": …}` or the bare string) is followed by its container id.
    private static func containerIDs(_ list: [JSONValue]) -> (pinned: String?, unpinned: String?) {
        var pinned: String?
        var unpinned: String?
        var index = 0
        while index + 1 < list.count {
            let kind = markerKind(list[index])
            if let kind, let id = list[index + 1].string {
                if kind == "pinned" { pinned = id } else { unpinned = id }
                index += 2
            } else {
                index += 1
            }
        }
        return (pinned, unpinned)
    }

    private static func markerKind(_ element: JSONValue) -> String? {
        if let text = element.string { return ["pinned", "unpinned"].contains(text) ? text : nil }
        guard let object = element.object else { return nil }
        if object["pinned"] != nil { return "pinned" }
        if object["unpinned"] != nil { return "unpinned" }
        return nil
    }

    private static func profileKey(_ marker: JSONValue?) -> ArcProfileKey {
        if case .bool(true)? = marker?["default"] { return .default }
        if let name = marker?["custom"]?["_0"]?["directoryBasename"]?.string {
            return .custom(directoryBasename: name)
        }
        return .unrecognized
    }

    private static func hexColor(_ midTone: JSONValue) -> String? {
        let channels = ["red", "green", "blue"].compactMap { midTone[$0]?.number }
        guard channels.count == 3 else { return nil }
        let bytes = channels.map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }

    // MARK: - Favorites

    /// Listed containers come first, in order; any other root `topApps` item follows, sorted by id.
    /// Lists for the same profile are concatenated in that order. Unrecognized markers are dropped.
    private static func parseFavorites(
        listed: [String],
        walk: inout Walk
    ) throws -> [ArcProfileKey: [ArcNode]] {
        let others = walk.items.keys.sorted()
        var result: [ArcProfileKey: [ArcNode]] = [:]
        var seen: Set<String> = []
        for id in listed + others where !seen.contains(id) {
            guard let item = walk.items[id], isRoot(item),
                  let marker = item["data"]?["itemContainer"]?["containerType"]?["topApps"]?["_0"]
            else { continue }
            seen.insert(id)
            let key = profileKey(marker)
            if key == .unrecognized { continue }
            result[key, default: []] += try nodes(inContainer: id, walk: &walk)
        }
        return result
    }

    private static func isRoot(_ item: [String: JSONValue]) -> Bool {
        item["parentID"] == nil || item["parentID"] == .null
    }

    // MARK: - Item trees

    private static func nodes(inContainer id: String?, walk: inout Walk) throws -> [ArcNode] {
        guard let id, let container = walk.items[id] else { return [] }
        return try children(of: container, walk: &walk, depth: 1)
    }

    /// `depth` is the nesting level of the children being read; an item deeper than `maximumDepth` throws.
    private static func children(
        of item: [String: JSONValue],
        walk: inout Walk,
        depth: Int
    ) throws -> [ArcNode] {
        var result: [ArcNode] = []
        for childID in item["childrenIds"]?.array ?? [] {
            guard let id = childID.string, let child = walk.items[id] else { continue }
            guard walk.visited.insert(id).inserted else {
                walk.duplicates += 1
                continue
            }
            guard depth <= maximumDepth else { throw ArcImportError.tooDeep }
            result.append(try node(child, walk: &walk, depth: depth))
        }
        return result
    }

    private static func node(
        _ item: [String: JSONValue],
        walk: inout Walk,
        depth: Int
    ) throws -> ArcNode {
        let data = item["data"]?.object ?? [:]
        if let tab = data["tab"] {
            return .tab(arcTab(item, tab))
        }
        if data["list"] != nil {
            let kids = try children(of: item, walk: &walk, depth: depth + 1)
            return .folder(title: item["title"]?.string ?? "", children: kids)
        }
        if data["splitView"] != nil {
            let kids = try children(of: item, walk: &walk, depth: depth + 1)
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
