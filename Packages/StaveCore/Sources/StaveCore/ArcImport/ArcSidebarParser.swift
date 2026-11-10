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
        // Visit order decides which copy of a repeated item wins: every space's pinned tree, then Favorites, then every space's unpinned tree.
        let pending = (container["spaces"]?.array ?? []).compactMap { $0.object.map(parseSpaceHeader) }
        let pinned = try pending.map { try nodes(inContainer: $0.containers.pinned, walk: &walk) }
        let favorites = try parseFavorites(
            listed: (container["topAppsContainerIDs"]?.array ?? []).compactMap(\.string),
            walk: &walk
        )
        let unpinned = try pending.map { try nodes(inContainer: $0.containers.unpinned, walk: &walk) }
        let spaces = pending.indices.map { index in
            let header = pending[index]
            return ArcSpace(
                title: header.title, profile: header.profile, emoji: header.emoji, colorHex: header.colorHex,
                pinned: pinned[index], unpinned: unpinned[index],
                contentsMissing: isMissing(header.containers, items: items)
            )
        }
        return ArcSidebar(
            spaces: spaces, favorites: favorites.byProfile, duplicateItems: walk.duplicates,
            unrecognizedFavoritesContainers: favorites.unrecognizedCount
        )
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

    /// A space's metadata and resolved container ids, before any items are walked.
    private struct SpaceHeader {
        var title: String?
        var profile: ArcProfileKey
        var emoji: String?
        var colorHex: String?
        var containers: (pinned: String?, unpinned: String?)
    }

    private static func parseSpaceHeader(_ space: [String: JSONValue]) -> SpaceHeader {
        let icon = space["customInfo"]?["iconType"]
        let midTone = space["customInfo"]?["windowTheme"]?["primaryColorPalette"]?["midTone"]
        return SpaceHeader(
            title: nonEmpty(space["title"]?.string),
            profile: space["profile"].map(profileKey) ?? .default,
            emoji: nonEmpty(icon?["emoji_v2"]?.string),
            colorHex: midTone.flatMap(hexColor),
            containers: resolveContainers(space)
        )
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Pinned and unpinned are each taken from `newContainerIDs`, falling back to the legacy `containerIDs`.
    private static func resolveContainers(_ space: [String: JSONValue]) -> (pinned: String?, unpinned: String?) {
        let current = containerIDs(space["newContainerIDs"]?.array ?? [])
        let legacy = containerIDs(space["containerIDs"]?.array ?? [])
        return (current.pinned ?? legacy.pinned, current.unpinned ?? legacy.unpinned)
    }

    /// No resolvable pinned container, or a resolved container id that is not among the items.
    private static func isMissing(
        _ containers: (pinned: String?, unpinned: String?),
        items: [String: [String: JSONValue]]
    ) -> Bool {
        guard let pinned = containers.pinned else { return true }
        return [pinned, containers.unpinned].compactMap { $0 }.contains { items[$0] == nil }
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

    private static func profileKey(_ marker: JSONValue) -> ArcProfileKey {
        if case .bool(true)? = marker["default"] { return .default }
        if let name = marker["custom"]?["_0"]?["directoryBasename"]?.string {
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
    /// Lists for the same profile are concatenated in that order. A container whose marker is missing or
    /// unrecognized is walked too: its nodes follow the default profile's own, and it is counted when it has at least one child item.
    private static func parseFavorites(
        listed: [String],
        walk: inout Walk
    ) throws -> (byProfile: [ArcProfileKey: [ArcNode]], unrecognizedCount: Int) {
        let others = walk.items.keys.sorted()
        var result: [ArcProfileKey: [ArcNode]] = [:]
        var strays: [ArcNode] = []
        var unrecognized = 0
        var seen: Set<String> = []
        for id in listed + others where !seen.contains(id) {
            guard let item = walk.items[id], isRoot(item),
                  let topApps = item["data"]?["itemContainer"]?["containerType"]?["topApps"]
            else { continue }
            seen.insert(id)
            let found = try nodes(inContainer: id, walk: &walk)
            switch topApps["_0"].map(profileKey) {
            case .some(let key) where key != .unrecognized:
                result[key, default: []] += found
            default:
                if !found.isEmpty { unrecognized += 1 }
                strays += found
            }
        }
        if !strays.isEmpty { result[.default, default: []] += strays }
        return (result, unrecognized)
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
        let kids = try children(of: item, walk: &walk, depth: depth + 1)
        return .unsupported(kind: data.keys.sorted().first ?? "", title: item["title"]?.string, children: kids)
    }

    private static func arcTab(_ item: [String: JSONValue], _ tab: JSONValue) -> ArcTab {
        ArcTab(
            url: tab["savedURL"]?.string ?? "",
            title: item["title"]?.string ?? tab["savedTitle"]?.string ?? ""
        )
    }
}
