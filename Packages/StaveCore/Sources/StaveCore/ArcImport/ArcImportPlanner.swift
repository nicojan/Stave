import Foundation

/// Turns a parsed `ArcSidebar` into a Stave-shaped plan plus report entries. Pure: no store, no I/O.
public enum ArcImportPlanner {
    public static let defaultIcon = "square.grid.2x2"
    public static let defaultColorHex = "#8E8E93"

    /// Stave folders nest this deep; a deeper Arc folder is flattened into its parent.
    private static let maxFolderDepth = 2

    private struct Notes {
        var flattened: [ArcImportReport.Flattened] = []
        var skipped: [ArcImportReport.Skipped] = []
    }

    public static func plan(
        _ sidebar: ArcSidebar,
        options: ArcImportOptions,
        profileNames: [String: String]
    ) -> ArcImportPlan {
        var notes = Notes()

        // Workspace names first, so "Space N" counts unnamed spaces in sidebar order.
        var unnamed = 0
        let names: [String] = sidebar.spaces.map { space in
            if let title = space.title, !title.isEmpty { return title }
            unnamed += 1
            return "Space \(unnamed)"
        }

        let labels = placeLabels(names)

        // Profile buckets keyed by custom basename; nil is the default profile.
        var order: [String?] = [nil]
        var workspaces: [String?: [PlannedWorkspace]] = [:]
        var essentials: [String?: [PlannedTab]] = [:]

        func bucket(for key: ArcProfileKey) -> String? {
            if case .custom(let basename) = key { return basename }
            return nil
        }
        func register(_ id: String?) {
            if !order.contains(where: { $0 == id }) { order.append(id) }
        }

        for (index, space) in sidebar.spaces.enumerated() {
            let id = bucket(for: space.profile)
            register(id)
            if space.profile == .unrecognized {
                notes.skipped.append(.unrecognizedProfile(space: labels[index]))
            }
            if space.contentsMissing {
                notes.skipped.append(.spaceContentsMissing(space: labels[index]))
            }
            let workspace = planWorkspace(space, name: names[index], label: labels[index], options: options, notes: &notes)
            workspaces[id, default: []].append(workspace)
        }

        // Favorites: dictionary order is arbitrary, so use default, unrecognized, then customs by basename.
        let favoriteKeys = sidebar.favorites.keys.sorted { sortRank($0) < sortRank($1) }
        let favoriteIDs = favoriteKeys.filter { !(sidebar.favorites[$0] ?? []).isEmpty }.map(bucket(for:))
        for id in favoriteIDs where id != nil { register(id) }
        // Report and plan in plan profile order.
        for id in order {
            for key in favoriteKeys where bucket(for: key) == id {
                let nodes = sidebar.favorites[key] ?? []
                let place = ArcImportReport.Place.favorites(profile: id.map { profileNames[$0] ?? $0 })
                essentials[id, default: []] += planFavorites(nodes, place: place, notes: &notes)
            }
        }

        notes.skipped += Array(repeating: .unrecognizedFavoritesProfile, count: sidebar.unrecognizedFavoritesContainers)

        if sidebar.duplicateItems > 0 {
            notes.skipped.append(.duplicateItem(count: sidebar.duplicateItems))
        }

        let profiles: [PlannedProfile] = order.compactMap { id in
            guard let id else {
                return PlannedProfile(target: .existingDefault, workspaces: workspaces[nil] ?? [], essentials: essentials[nil] ?? [])
            }
            let ws = workspaces[id] ?? []
            let es = essentials[id] ?? []
            guard !ws.isEmpty || !es.isEmpty else { return nil }
            return PlannedProfile(target: .new(name: profileNames[id] ?? id), workspaces: ws, essentials: es)
        }
        return ArcImportPlan(profiles: profiles, flattened: notes.flattened, skipped: notes.skipped)
    }

    private static func sortRank(_ key: ArcProfileKey) -> String {
        switch key {
        case .default: return "0"
        case .unrecognized: return "1"
        case .custom(let basename): return "2" + basename
        }
    }

    /// Report labels: the name, plus " (n)" when two or more spaces share it (n is 1-based, in sidebar order).
    private static func placeLabels(_ names: [String]) -> [String] {
        let totals = names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return names.map { name in
            guard totals[name, default: 0] > 1 else { return name }
            seen[name, default: 0] += 1
            return "\(name) (\(seen[name] ?? 0))"
        }
    }

    // MARK: - Workspaces

    private static func planWorkspace(
        _ space: ArcSpace,
        name: String,
        label: String,
        options: ArcImportOptions,
        notes: inout Notes
    ) -> PlannedWorkspace {
        let pinned = planPinned(space.pinned, depth: 0, space: label, notes: &notes)
        var regular: [PlannedTab] = []
        if options.includeUnpinnedTabs {
            regular = planFlat(space.unpinned, place: .space(label), folderNote: .unpinned(label), notes: &notes)
        } else {
            let count = countWebTabs(space.unpinned)
            if count > 0 { notes.skipped.append(.unpinnedTabs(space: label, count: count)) }
        }
        return PlannedWorkspace(
            name: name,
            icon: space.emoji.flatMap { $0.isEmpty ? nil : $0 } ?? defaultIcon,
            colorHex: space.colorHex ?? defaultColorHex,
            pinned: pinned,
            regular: regular
        )
    }

    /// `depth` is the folder depth of the container the nodes sit in (0 at the root).
    private static func planPinned(
        _ nodes: [ArcNode],
        depth: Int,
        space: String,
        notes: inout Notes
    ) -> [PlannedPinned] {
        var result: [PlannedPinned] = []
        for node in nodes {
            switch node {
            case .tab(let tab):
                if let planned = acceptTab(tab, place: .space(space), notes: &notes) { result.append(.tab(planned)) }
            case .folder(let title, let children):
                if depth + 1 <= maxFolderDepth {
                    result.append(.folder(title: title, children: planPinned(children, depth: depth + 1, space: space, notes: &notes)))
                } else {
                    notes.flattened.append(.folderTooDeep(space: space, folder: title))
                    result += planPinned(children, depth: depth + 1, space: space, notes: &notes)
                }
            case .split(let tabs):
                notes.flattened.append(.splitView(place: .space(space), tabCount: tabs.count))
                result += tabs.compactMap { acceptTab($0, place: .space(space), notes: &notes) }.map { .tab($0) }
            case .unsupported(let kind, let title, let children):
                notes.skipped.append(.unsupportedItem(place: .space(space), kind: kind, title: title))
                result += planPinned(children, depth: depth, space: space, notes: &notes)
            }
        }
        return result
    }

    // MARK: - Flat lists (regular tabs, Favorites)

    private enum FolderNote {
        case unpinned(String)   // space name
        case favorites
    }

    private static func planFlat(
        _ nodes: [ArcNode],
        place: ArcImportReport.Place,
        folderNote: FolderNote,
        notes: inout Notes
    ) -> [PlannedTab] {
        var result: [PlannedTab] = []
        for node in nodes {
            switch node {
            case .tab(let tab):
                if let planned = acceptTab(tab, place: place, notes: &notes) { result.append(planned) }
            case .folder(let title, let children):
                switch folderNote {
                case .unpinned(let name): notes.flattened.append(.unpinnedFolder(space: name, folder: title))
                case .favorites: notes.flattened.append(.favoritesFolder(folder: title))
                }
                result += planFlat(children, place: place, folderNote: folderNote, notes: &notes)
            case .split(let tabs):
                notes.flattened.append(.splitView(place: place, tabCount: tabs.count))
                result += tabs.compactMap { acceptTab($0, place: place, notes: &notes) }
            case .unsupported(let kind, let title, let children):
                notes.skipped.append(.unsupportedItem(place: place, kind: kind, title: title))
                result += planFlat(children, place: place, folderNote: folderNote, notes: &notes)
            }
        }
        return result
    }

    private static func planFavorites(_ nodes: [ArcNode], place: ArcImportReport.Place, notes: inout Notes) -> [PlannedTab] {
        planFlat(nodes, place: place, folderNote: .favorites, notes: &notes)
    }

    // MARK: - URL filter (ruling 1)

    /// The text before the first ":" when it is a syntactically valid scheme, lowercased; otherwise "".
    /// Deliberately independent of `URL(string:)`, whose handling of spaces and non-ASCII differs by OS version.
    private static func scheme(of url: String) -> String {
        guard let colon = url.firstIndex(of: ":") else { return "" }
        let prefix = url[url.startIndex..<colon]
        guard let first = prefix.unicodeScalars.first, isASCIILetter(first) else { return "" }
        let valid = prefix.unicodeScalars.allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0) }
        return valid ? prefix.lowercased() : ""
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// http or https, then "//" and a non-empty host (authority up to the first "/", "?" or "#").
    private static func isWeb(_ url: String) -> Bool {
        let scheme = scheme(of: url)
        guard scheme == "http" || scheme == "https" else { return false }
        let rest = url.dropFirst(scheme.count + 1)
        guard rest.hasPrefix("//") else { return false }
        let authority = rest.dropFirst(2).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return !authority.isEmpty
    }

    private static func acceptTab(_ tab: ArcTab, place: ArcImportReport.Place, notes: inout Notes) -> PlannedTab? {
        guard isWeb(tab.url) else {
            notes.skipped.append(.nonWebURL(place: place, title: tab.title, scheme: scheme(of: tab.url)))
            return nil
        }
        return PlannedTab(url: tab.url, title: tab.title)
    }

    private static func countWebTabs(_ nodes: [ArcNode]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .tab(let tab): return total + (isWeb(tab.url) ? 1 : 0)
            case .folder(_, let children): return total + countWebTabs(children)
            case .split(let tabs): return total + tabs.filter { isWeb($0.url) }.count
            case .unsupported(_, _, let children): return total + countWebTabs(children)
            }
        }
    }
}
