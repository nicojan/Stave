import Foundation

public enum SearchEngine: String, Codable, Sendable, CaseIterable {
    case google, duckDuckGo, kagi, bing, ecosia

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .bing: "Bing"
        case .ecosia: "Ecosia"
        }
    }

    private var searchPrefix: String {
        switch self {
        case .google: "https://www.google.com/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        case .kagi: "https://kagi.com/search?q="
        case .bing: "https://www.bing.com/search?q="
        case .ecosia: "https://www.ecosia.org/search?q="
        }
    }

    /// `.urlQueryAllowed` minus the characters that would end or split the query value.
    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#/")
        return set
    }()

    public func searchURL(for query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? ""
        return searchPrefix + encoded
    }
}
