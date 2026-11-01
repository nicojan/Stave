import Foundation
import Observation

public enum DownloadOwner: Hashable, Sendable {
    case profile(UUID)
    case privateWindow(UUID)
}

public enum DownloadState: Equatable, Sendable {
    case running(fraction: Double?)
    case finished(URL)
    case failed(String)
    case cancelled

    var hasEnded: Bool {
        if case .running = self { return false }
        return true
    }
}

public struct DownloadItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let owner: DownloadOwner
    public let filename: String
    public let sourceHost: String?
    public var state: DownloadState
}

/// In-memory downloads per owner (a profile or a private window), newest first. A row ends once:
/// after finished, failed or cancelled, later reports for it are ignored.
@MainActor @Observable
public final class DownloadList {
    private var rows: [DownloadItem] = []   // oldest first; `items(for:)` reverses
    @ObservationIgnored public var onCancel: ((UUID) -> Void)?

    public init() {}

    public func items(for owner: DownloadOwner) -> [DownloadItem] {
        rows.filter { $0.owner == owner }.reversed()
    }

    public func begin(owner: DownloadOwner, filename: String, sourceHost: String?) -> UUID {
        let id = UUID()
        rows.append(DownloadItem(id: id, owner: owner, filename: filename, sourceHost: sourceHost, state: .running(fraction: nil)))
        return id
    }

    public func progress(_ id: UUID, fraction: Double?) {
        update(id, to: .running(fraction: fraction.map { min(max($0, 0), 1) }))
    }

    public func finish(_ id: UUID, at url: URL) { update(id, to: .finished(url)) }

    public func fail(_ id: UUID, message: String) { update(id, to: .failed(message)) }

    public func cancel(_ id: UUID) {
        guard update(id, to: .cancelled) else { return }
        onCancel?(id)
    }

    public func clearFinished(owner: DownloadOwner) {
        rows.removeAll { $0.owner == owner && $0.state.hasEnded }
    }

    public func dropOwner(_ owner: DownloadOwner) {
        rows.removeAll { $0.owner == owner }
    }

    /// Returns true when the row was running and changed.
    @discardableResult
    private func update(_ id: UUID, to state: DownloadState) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].state.hasEnded else { return false }
        rows[index].state = state
        return true
    }
}

public enum DownloadFilename {
    static let maxBytes = 200
    static let maxExtensionBytes = 32

    /// Makes a server- or page-suggested name safe to use as a file name.
    public static func sanitized(_ suggested: String) -> String {
        let noControls = String(String.UnicodeScalarView(suggested.unicodeScalars.filter { !isControl($0) }))
        let leading: Set<Character> = [".", " ", "/", ":"]
        var rest = Substring(noControls)
        while let first = rest.first, leading.contains(first) { rest = rest.dropFirst() }
        let replaced = String(rest.map { $0 == "/" || $0 == ":" ? Character("-") : $0 })
        let capped = cap(replaced)
        return capped.isEmpty ? "download" : capped
    }

    /// `directory/name`, or `directory/stem (2).ext`, `(3)`, … until `exists` says the path is free.
    public static func unique(_ name: String, in directory: URL, exists: (URL) -> Bool) -> URL {
        var leaf = (name as NSString).lastPathComponent
        if leaf.isEmpty || leaf == "." || leaf == ".." { leaf = "download" }
        let first = directory.appendingPathComponent(leaf)
        guard exists(first) else { return first }
        let (stem, ext) = split(leaf)
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) (\(n))\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: Helpers

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true   // bidi marks and overrides
        default: return false
        }
    }

    /// Splits at the last "." that is not the first character; `ext` includes the dot.
    private static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    private static func cap(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var (stem, ext) = split(name)
        if ext.utf8.count > maxExtensionBytes { (stem, ext) = (name, "") }
        let budget = maxBytes - ext.utf8.count
        var kept = ""
        var used = 0
        for character in stem {
            let size = String(character).utf8.count
            if used + size > budget { break }
            kept.append(character)
            used += size
        }
        return kept + ext
    }
}
