import Foundation

/// Builders for small synthetic `StorableSidebar.json` documents, so a test can state exactly the shape it needs.

/// One item object. `data` is raw JSON for the item's `data` value.
func arcItemJSON(_ id: String, parent: String? = nil, children: [String] = [], title: String? = nil, data: String) -> String {
    let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
    let titleJSON = title.map { "\"\($0)\"" } ?? "null"
    let kids = children.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"id":"\#(id)","parentID":\#(parentJSON),"childrenIds":[\#(kids)],"title":\#(titleJSON),"data":\#(data)}"#
}

func arcTabJSON(_ id: String, parent: String, url: String, title: String? = nil) -> String {
    arcItemJSON(id, parent: parent, title: title, data: #"{"tab":{"savedURL":"\#(url)"}}"#)
}

/// A root container item for a space (pinned or unpinned list).
func arcSpaceContainerJSON(_ id: String, children: [String]) -> String {
    arcItemJSON(id, children: children, data: #"{"itemContainer":{"containerType":{"spaceItems":{"_0":"S"}}}}"#)
}

/// A root `topApps` container. `marker` is the raw JSON of `_0`, or nil to leave `_0` out.
func arcFavoritesJSON(_ id: String, children: [String], marker: String?) -> String {
    let inner = marker.map { #"{"_0":\#($0)}"# } ?? "{}"
    return arcItemJSON(id, children: children, data: #"{"itemContainer":{"containerType":{"topApps":\#(inner)}}}"#)
}

/// A space object. `fields` is raw JSON members, e.g. `"title":"A","profile":{"default":true}`.
func arcSpaceJSON(_ id: String, _ fields: String) -> String {
    #"{"id":"\#(id)",\#(fields)}"#
}

func arcSidebarData(items: [String], spaces: [String]) -> Data {
    Data(#"{"sidebar":{"containers":[{"items":[\#(items.joined(separator: ","))],"spaces":[\#(spaces.joined(separator: ","))],"topAppsContainerIDs":[]}]}}"#.utf8)
}
