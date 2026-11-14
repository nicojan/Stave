import Foundation
import StaveCore
import WebKit

/// The downloads WebKit is running, keyed by `DownloadList` row ID. Each entry keeps its page delegate
/// alive (WebKit holds a download's delegate weakly), so a download outlives the tab that started it.
@MainActor
final class ActiveDownloads {
    private final class Entry {
        let download: WKDownload
        let delegate: PageDelegate
        var rowID: UUID?
        weak var list: DownloadList?
        /// Only ever the destination the delegate returned to WebKit for this download (set in `begin`).
        var destination: URL?
        /// The destination file's identity, captured when WebKit first reports bytes written (WebKit creates the file with its first
        /// write, not when the destination is chosen; checked against a slow local server). Nil until then: such a file is never deleted.
        var fileIdentity: FileIdentity?
        var source: URL?
        var observation: NSKeyValueObservation?

        init(download: WKDownload, delegate: PageDelegate) {
            self.download = download
            self.delegate = delegate
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Row ID → download, for `DownloadList.onCancel`.
    private var byRow: [UUID: WKDownload] = [:]
    /// The list whose `onCancel` already reaches here.
    private weak var wiredList: DownloadList?
    /// Seam for tests: how a file is quarantined.
    var mark: @MainActor (URL, URL?) throws -> Void = { try Quarantine.mark($0, source: $1) }

    func track(_ download: WKDownload, delegate: PageDelegate) {
        download.delegate = delegate
        if entries[ObjectIdentifier(download)] == nil {
            entries[ObjectIdentifier(download)] = Entry(download: download, delegate: delegate)
        }
    }

    func begin(_ download: WKDownload, delegate: PageDelegate, rowID: UUID, list: DownloadList, destination: URL, source: URL?) {
        let key = ObjectIdentifier(download)
        let entry = entries[key] ?? Entry(download: download, delegate: delegate)
        entries[key] = entry
        entry.rowID = rowID
        entry.list = list
        entry.destination = destination
        entry.source = source
        byRow[rowID] = download
        wireCancel(list)
        // Bytes written, not the fraction: with no known length the fraction never moves, but the bytes do.
        entry.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { @Sendable [weak self] progress, _ in
            let fraction: Double? = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            let wrote = progress.completedUnitCount > 0
            Task { @MainActor in
                if wrote { self?.claimDestination(forRow: rowID) }
                self?.progress(rowID, fraction: fraction)
            }
        }
    }

    /// Records the destination file's identity as this download's, once, and quarantines it at once, so the file is never in the
    /// Downloads folder unmarked while it is written. Called when WebKit has written bytes, so the file there is the one WebKit created for
    /// it (WebKit fails rather than write into a file it did not create). A mark that fails here is tried again at the end, where a file
    /// that still can't be marked is removed.
    func claimDestination(forRow rowID: UUID) {
        guard let download = byRow[rowID], let entry = entries[ObjectIdentifier(download)] else { return }
        claim(entry)
    }

    private func claim(_ entry: Entry) {
        guard entry.fileIdentity == nil, let destination = entry.destination,
              let identity = FileIdentity(of: destination) else { return }
        entry.fileIdentity = identity
        do {
            try mark(destination, entry.source)
        } catch {
            NSLog("Stave: could not quarantine a download as it started: \(error)")
        }
    }

    func download(forRow rowID: UUID) -> WKDownload? {
        byRow[rowID]
    }

    /// Quarantines the file with its source URL again, then marks the row finished. A file that WebKit wrote without ever reporting
    /// progress (an empty one) is claimed here: WebKit has just finished writing it. When the mark fails, the file is removed, but only
    /// when it is provably this download's (`removeIfOwn`), and the row fails: a download is never left in the folder unmarked.
    func finished(_ download: WKDownload) {
        guard let entry = remove(download), let rowID = entry.rowID, let destination = entry.destination else { return }
        claim(entry)
        do {
            try mark(destination, entry.source)
            entry.list?.finish(rowID, at: destination)
        } catch {
            removeIfOwn(entry)
            entry.list?.fail(rowID, message: error.localizedDescription)
        }
    }

    /// The row fails; whatever WebKit left of a claimed file is quarantined, or removed (only when provably this download's) when it
    /// can't be.
    func failed(_ download: WKDownload, message: String) {
        guard let entry = remove(download), let rowID = entry.rowID else { return }
        if let destination = entry.destination, let identity = entry.fileIdentity, FileIdentity(of: destination) == identity {
            do {
                try mark(destination, entry.source)
            } catch {
                removeIfOwn(entry)
            }
        }
        entry.list?.fail(rowID, message: message)
    }

    /// Removes the entry's file only when its identity was captured from WebKit's own write and the file at the path still has it; a
    /// foreign file, or one swapped in since, is never touched.
    private func removeIfOwn(_ entry: Entry) {
        guard let destination = entry.destination, let identity = entry.fileIdentity, FileIdentity(of: destination) == identity else { return }
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            NSLog("Stave: could not remove a download's file: \(error)")
        }
    }

    /// Stops the download and removes what it had written. WebKit leaves the partial file at the destination on cancel (checked against a
    /// slow local server), so the file goes, but only when it is provably this download's: its identity was captured from WebKit's own
    /// write and the file at the path still has it. Anything else (never claimed, or replaced since) stays; a leftover partial is acceptable,
    /// a wrongly deleted file is not. Deleted once, here: the name it frees may go to the next download of the same file at once. A finished
    /// download is no longer in `entries`, so its file is never touched.
    func cancel(row rowID: UUID) {
        guard let download = byRow[rowID] else { return }
        let entry = remove(download)
        download.cancel(nil)
        if let entry { removeIfOwn(entry) }
    }

    private func progress(_ rowID: UUID, fraction: Double?) {
        guard let download = byRow[rowID], let entry = entries[ObjectIdentifier(download)] else { return }
        entry.list?.progress(rowID, fraction: fraction)
    }

    @discardableResult
    private func remove(_ download: WKDownload) -> Entry? {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        entry.observation?.invalidate()
        if let rowID = entry.rowID { byRow[rowID] = nil }
        return entry
    }

    /// Chains onto the list's existing `onCancel` once, so another owner's handler still runs.
    private func wireCancel(_ list: DownloadList) {
        guard wiredList !== list else { return }
        wiredList = list
        let previous = list.onCancel
        list.onCancel = { [weak self] rowID in
            previous?(rowID)
            self?.cancel(row: rowID)
        }
    }
}

/// A file's device and inode: which file a path names now, so a file swapped in at the same path is told apart from the one recorded.
struct FileIdentity: Equatable {
    let device: Int
    let inode: Int

    /// Nil when nothing (or no regular file) is at the path.
    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let device = (attributes[.systemNumber] as? NSNumber)?.intValue,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.intValue else { return nil }
        self.device = device
        self.inode = inode
    }
}
