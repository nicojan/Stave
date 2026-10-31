import Foundation
import Observation

/// Drives one Arc import for the import sheet: ready, an optional "you already did this" confirmation, importing, then finished or failed. The import itself runs off the main actor.
@MainActor @Observable
public final class ArcImportFlow {
    public enum Source: Equatable, Sendable {
        case arcOnThisMac(home: URL)
        case pickedFile(URL)
    }

    public enum Phase: Equatable {
        case ready
        case confirmRepeat(previous: Date)
        case importing
        case finished(ArcImportSummary)
        case failed(String)
    }

    public var includeUnpinnedTabs = false
    public private(set) var phase: Phase = .ready
    /// When Arc was last imported, or nil. Read at init and again after each successful import.
    public private(set) var previousImport: Date?

    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let revision: StoreRevision
    @ObservationIgnored private let source: Source
    @ObservationIgnored private let readLastImport: @Sendable (OrganizationStore) throws -> Date?
    /// True when the import history couldn't be read, so "no earlier import" is unknown and nothing is imported.
    @ObservationIgnored private var historyUnreadable = false

    public convenience init(store: OrganizationStore, revision: StoreRevision, source: Source) {
        self.init(store: store, revision: revision, source: source, readLastImport: { try $0.lastImport(source: .arc) })
    }

    /// `readLastImport` is injectable so tests can make the history read fail.
    init(
        store: OrganizationStore,
        revision: StoreRevision,
        source: Source,
        readLastImport: @escaping @Sendable (OrganizationStore) throws -> Date?
    ) {
        self.store = store
        self.revision = revision
        self.source = source
        self.readLastImport = readLastImport
        refreshHistory()
    }

    /// With an earlier import (including one this flow just made), asks for confirmation first; otherwise imports. A no-op while importing.
    public func start() async {
        guard phase != .importing else { return }
        guard historyIsKnown() else { return }
        if let previous = previousImport {
            phase = .confirmRepeat(previous: previous)
            return
        }
        await run()
    }

    /// Imports again after the user confirmed. A no-op while importing.
    public func confirmRepeat() async {
        guard phase != .importing else { return }
        guard historyIsKnown() else { return }
        await run()
    }

    public func cancelRepeat() {
        if case .confirmRepeat = phase { phase = .ready }
    }

    /// Offer the import on first run when Arc's file is there, nothing was imported and the first-run screen hasn't been completed.
    public static func shouldOfferOnFirstRun(arcHome: URL, store: OrganizationStore) throws -> Bool {
        guard ArcImporter.isAvailable(home: arcHome) else { return false }
        guard try store.lastImport(source: .arc) == nil else { return false }
        return try store.setting(SettingKeys.firstRunCompleted) == false
    }

    /// Reads the history (again, if it was unreadable). When it still can't be read, fails safe: no import.
    private func historyIsKnown() -> Bool {
        if historyUnreadable { refreshHistory() }
        if historyUnreadable { phase = .failed(ArcImportCopy.historyUnreadable) }
        return !historyUnreadable
    }

    private func refreshHistory() {
        do {
            previousImport = try readLastImport(store)
            historyUnreadable = false
        } catch {
            historyUnreadable = true
        }
    }

    private func run() async {
        phase = .importing
        let store = store
        let source = source
        let options = ArcImportOptions(includeUnpinnedTabs: includeUnpinnedTabs)
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ArcImportReport, Error> in
            let file: URL
            switch source {
            case .arcOnThisMac(let home): file = ArcImporter.sidebarFile(home: home)
            case .pickedFile(let url): file = url
            }
            return Result {
                try ArcImporter.run(
                    sidebarFile: file,
                    localStateFile: ArcImporter.localStateFile(nextTo: file),
                    options: options,
                    into: store
                )
            }
        }.value
        switch outcome {
        case .success(let report):
            // A record was just written, so there is an import date: if the re-read fails, use this moment.
            previousImport = (try? readLastImport(store)) ?? store.now()
            revision.bump()
            phase = .finished(ArcImportSummary(report: report))
        case .failure(let error):
            phase = .failed(ArcImportCopy.errorMessage(for: error))
        }
    }
}
