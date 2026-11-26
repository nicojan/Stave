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
    /// A download that was still running when Stave quit: listed after the relaunch as stopped (no resume in the beta).
    case stopped

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
    public let startedAt: Date
    public var endedAt: Date?

    init(id: UUID, owner: DownloadOwner, filename: String, sourceHost: String?, state: DownloadState, startedAt: Date = Date(), endedAt: Date? = nil) {
        self.id = id; self.owner = owner; self.filename = filename; self.sourceHost = sourceHost
        self.state = state; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// Downloads per owner (a profile or a private window), newest first. A profile's rows are kept in the database when the list has a store
/// (decision 33): they survive a relaunch, and "Remove download list items" trims them. A private window's rows are in memory only and go
/// when its window closes. A row ends once: after finished, failed or cancelled, later reports for it are ignored. Removing a row never
/// touches the downloaded file.
@MainActor @Observable
public final class DownloadList {
    private var rows: [DownloadItem] = []   // oldest first; `items(for:)` reverses
    /// The owners that have at least one row. It changes only when a row is added or removed, never on a progress or state update, so the
    /// menus read it (`hasItems(for:)`) instead of `items(for:)` and do not rebuild on every progress tick.
    private var ownersWithItems: Set<DownloadOwner> = []
    @ObservationIgnored public var onCancel: ((UUID) -> Void)?
    /// A write to the kept list failed. The download itself goes on; only its row is not kept.
    @ObservationIgnored public var onPersistError: (@MainActor (Error) -> Void)?
    @ObservationIgnored private let store: OrganizationStore?
    @ObservationIgnored private let retention: () -> DownloadListRetention
    @ObservationIgnored private let now: () -> Date

    /// A day, in seconds: what "After one day" keeps.
    public static let dayRetention: TimeInterval = 86_400

    /// `store` nil keeps every row in memory only (tests, and a store that did not open).
    public init(store: OrganizationStore? = nil, retention: @escaping () -> DownloadListRetention = { .day }, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.retention = retention
        self.now = now
    }

    public func items(for owner: DownloadOwner) -> [DownloadItem] {
        rows.filter { $0.owner == owner }.reversed()
    }

    /// Whether the owner has any row. Observers of this are told only when that flips.
    public func hasItems(for owner: DownloadOwner) -> Bool { ownersWithItems.contains(owner) }

    public func begin(owner: DownloadOwner, filename: String, sourceHost: String?) -> UUID {
        let id = UUID()
        let item = DownloadItem(id: id, owner: owner, filename: filename, sourceHost: sourceHost, state: .running(fraction: nil), startedAt: now(), endedAt: nil)
        rows.append(item)
        if !ownersWithItems.contains(owner) { ownersWithItems.insert(owner) }
        if let profileID = Self.profileID(of: owner) {
            persist { try $0.recordDownloadStarted(id: id, profileID: profileID, filename: filename, sourceHost: sourceHost, at: item.startedAt) }
        }
        return id
    }

    public func progress(_ id: UUID, fraction: Double?) {
        // A NaN fraction (a zero total from a misbehaving server) says nothing; the row keeps what it showed.
        if let fraction, fraction.isNaN { return }
        update(id, to: .running(fraction: fraction.map { min(max($0, 0), 1) }))
    }

    public func finish(_ id: UUID, at url: URL) {
        guard update(id, to: .finished(url)) else { return }
        persistEnd(id, state: .finished, filePath: url.path)
        // "Upon successful download": the row goes as soon as the file is done; a failed or stopped row stays until it is removed by hand.
        if retention() == .onSuccess { remove(ids: [id]) }
    }

    public func fail(_ id: UUID, message: String) {
        guard update(id, to: .failed(message)) else { return }
        persistEnd(id, state: .failed, filePath: nil)
    }

    public func cancel(_ id: UUID) {
        guard update(id, to: .cancelled) else { return }
        persistEnd(id, state: .cancelled, filePath: nil)
        onCancel?(id)
    }

    public func clearFinished(owner: DownloadOwner) {
        rows.removeAll { $0.owner == owner && $0.state.hasEnded }
        refreshOwners()
        if let profileID = Self.profileID(of: owner) {
            persist { try $0.deleteEndedDownloads(profileID: profileID, startedSince: nil) }
        }
    }

    /// Cancels every row of the owner that is still running, each through `cancel` (so `onCancel` stops its download). A private window
    /// does this before `dropOwner` when it closes: finished files stay, half-written ones do not.
    public func cancelRunning(owner: DownloadOwner) {
        let running = rows.filter { $0.owner == owner && !$0.state.hasEnded }.map(\.id)
        for id in running { cancel(id) }
    }

    public func dropOwner(_ owner: DownloadOwner) {
        rows.removeAll { $0.owner == owner }
        refreshOwners()
    }

    // MARK: Kept list

    /// At launch, before any download starts: the kept list comes back in three steps, in this order. Loading first and trimming before
    /// the stop-marking means the launch trim only removes rows that had already ended; a download still running when Stave quit then
    /// shows as Stopped, even under "When Stave quits" (it is trimmed at the next launch like any ended row).
    private var leftoverRunning: Set<UUID> = []

    public func restoreAtLaunch() {
        loadPersisted()
        trimAtLaunch()
        stopLeftoverRunning()
    }

    /// Loads every profile's kept rows as stored. A row still running when Stave quit loads as running until `stopLeftoverRunning`.
    func loadPersisted() {
        guard let store else { return }
        do {
            let known = Set(rows.map(\.id))
            let records = try store.downloadRecords().filter { !known.contains($0.id) }
            leftoverRunning.formUnion(records.filter { $0.state == .running }.map(\.id))
            let loaded = records.map(Self.item(from:))
            rows = loaded + rows
            refreshOwners()
        } catch {
            NSLog("Stave: could not load the downloads list: \(error)")
            onPersistError?(error)
        }
    }

    /// At launch only, after the trim: every row still running was left by the last run (nothing has started yet), and there is no resume
    /// in the beta, so it is stopped, in the database too.
    public func stopLeftoverRunning() {
        let stamp = now()
        for index in rows.indices where leftoverRunning.contains(rows[index].id) {
            rows[index].state = .stopped
            rows[index].endedAt = stamp
        }
        leftoverRunning = []
        persist { _ = try $0.markRunningDownloadsStopped(at: stamp) }
    }

    /// Launch maintenance: "After one day" and "When Stave quits" (for a quit that didn't finish) both trim here.
    public func trimAtLaunch() {
        trimDaily()
        trimAtQuit()
    }

    /// The daily tick: with "After one day", ended rows whose download ended more than a day ago go. Never a file, never a running row.
    public func trimDaily() {
        guard retention() == .day else { return }
        let cutoff = now().addingTimeInterval(-Self.dayRetention)
        let old = rows.filter { Self.profileID(of: $0.owner) != nil && $0.state.hasEnded && ($0.endedAt ?? $0.startedAt) < cutoff }.map(\.id)
        remove(ids: old)
        persist { try $0.deleteEndedDownloads(profileID: nil, endedBefore: cutoff) }
    }

    /// With "When Stave quits": every ended profile row goes. A download still running is kept (it is stopped at the next launch).
    public func trimAtQuit() {
        guard retention() == .onQuit else { return }
        let ended = rows.filter { Self.profileID(of: $0.owner) != nil && $0.state.hasEnded }.map(\.id)
        remove(ids: ended)
        persist { try $0.deleteEndedDownloads(profileID: nil, startedSince: nil) }
    }

    /// Clear History: the owner's ended rows that started at or after `since` (all of them when nil) leave the open list. The database rows
    /// are removed by `OrganizationStore.clearHistory`; this only keeps what is shown in step.
    public func forgetEnded(owner: DownloadOwner, since: Date?) {
        rows.removeAll { row in
            guard row.owner == owner, row.state.hasEnded else { return false }
            guard let since else { return true }
            return row.startedAt >= since
        }
        refreshOwners()
    }

    private func remove(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        rows.removeAll { gone.contains($0.id) }
        refreshOwners()
        persist { try $0.deleteDownloadRecords(ids: ids) }
    }

    private func refreshOwners() {
        let owners = Set(rows.map(\.owner))
        if owners != ownersWithItems { ownersWithItems = owners }
    }

    private func persistEnd(_ id: UUID, state: DownloadRecordState, filePath: String?) {
        guard let row = rows.first(where: { $0.id == id }), Self.profileID(of: row.owner) != nil else { return }
        let at = row.endedAt ?? now()
        persist { try $0.recordDownloadEnded(id: id, state: state, filePath: filePath, at: at) }
    }

    private func persist(_ work: (OrganizationStore) throws -> Void) {
        guard let store else { return }
        do {
            try work(store)
        } catch {
            NSLog("Stave: could not keep a download in the list: \(error)")
            onPersistError?(error)
        }
    }

    private static func profileID(of owner: DownloadOwner) -> UUID? {
        if case .profile(let id) = owner { return id }
        return nil
    }

    private static func item(from record: DownloadRecord) -> DownloadItem {
        let state: DownloadState
        switch record.state {
        case .finished: state = record.filePath.map { .finished(URL(fileURLWithPath: $0)) } ?? .stopped
        case .failed: state = .failed("")
        case .cancelled: state = .cancelled
        case .running: state = .running(fraction: nil)
        case .stopped: state = .stopped
        }
        return DownloadItem(
            id: record.id, owner: .profile(record.profileID), filename: record.filename, sourceHost: record.sourceHost,
            state: state, startedAt: record.startedAt, endedAt: record.endedAt
        )
    }

    /// Returns true when the row was running and changed.
    @discardableResult
    private func update(_ id: UUID, to state: DownloadState) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), !rows[index].state.hasEnded else { return false }
        rows[index].state = state
        if state.hasEnded { rows[index].endedAt = now() }
        return true
    }
}

public enum DownloadFilename {
    static let maxBytes = 200
    static let maxExtensionBytes = 32

    /// Makes a server- or page-suggested name safe to use as a file name.
    public static func sanitized(_ suggested: String) -> String {
        let noControls = String(String.UnicodeScalarView(suggested.unicodeScalars.filter { !isControl($0) }))
        // Scalar level: "/" followed by a combining mark or ZWJ is one Character, not "/".
        let leading: Set<Unicode.Scalar> = [".", " ", "/", ":"]
        var scalars = Substring(noControls).unicodeScalars
        while let first = scalars.first, leading.contains(first) || isFormatOrMark(first) {
            scalars = scalars.dropFirst()
        }
        var replacedScalars = String.UnicodeScalarView()
        for scalar in scalars { replacedScalars.append(scalar == "/" || scalar == ":" ? "-" : scalar) }
        let replaced = String(replacedScalars)
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
        case 0x061C, 0x2028, 0x2029, 0x200B...0x200D, 0x2060, 0xFEFF: return true   // Arabic letter mark, line and paragraph separators, zero-width characters, word joiner, BOM
        // Soft hyphen, combining grapheme joiner, Mongolian vowel separator, invisible math operators, Hangul fillers (blank-looking letters).
        // U+200C and U+200D go too, as the spec says: that breaks emoji ZWJ sequences and Persian and Indic names (Nico has been told).
        case 0x00AD, 0x034F, 0x180E, 0x2061...0x2064, 0x115F, 0x1160, 0x3164, 0xFFA0: return true
        default: return false
        }
    }

    /// A format character or a combining mark (nonspacing, spacing or enclosing) can't start a name: it would attach to whatever is drawn
    /// before it.
    private static func isFormatOrMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// Splits at the last "." that is not the first character; `ext` includes the dot. A compressed tarball keeps both parts as its
    /// extension (`a.tar.gz` is `a` and `.tar.gz`), so numbering gives `a (2).tar.gz`.
    private static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let stem = name[..<dot]
        if let tarDot = stem.lastIndex(of: "."), tarDot != stem.startIndex, stem[tarDot...].lowercased() == ".tar" {
            return (String(name[..<tarDot]), String(name[tarDot...]))
        }
        return (String(stem), String(name[dot...]))
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
