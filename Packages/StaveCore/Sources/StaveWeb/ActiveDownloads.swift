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
        var destination: URL?
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
        entry.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { @Sendable [weak self] progress, _ in
            let fraction: Double? = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            Task { @MainActor in self?.progress(rowID, fraction: fraction) }
        }
    }

    func download(forRow rowID: UUID) -> WKDownload? {
        byRow[rowID]
    }

    /// Quarantines the file with its source URL, then marks the row finished.
    func finished(_ download: WKDownload) {
        guard let entry = remove(download), let rowID = entry.rowID, let destination = entry.destination else { return }
        do {
            try Quarantine.mark(destination, source: entry.source)
            entry.list?.finish(rowID, at: destination)
        } catch {
            entry.list?.fail(rowID, message: error.localizedDescription)
        }
    }

    func failed(_ download: WKDownload, message: String) {
        guard let entry = remove(download), let rowID = entry.rowID else { return }
        entry.list?.fail(rowID, message: message)
    }

    func cancel(row rowID: UUID) {
        guard let download = byRow[rowID] else { return }
        remove(download)
        download.cancel(nil)
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
