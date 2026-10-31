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

    public init(store: OrganizationStore, revision: StoreRevision, source: Source) {
        self.store = store
        self.revision = revision
        self.source = source
        self.previousImport = try? store.lastImport(source: .arc)
    }

    /// With an earlier import (including one this flow just made), asks for confirmation first; otherwise imports. A no-op while importing.
    public func start() async {
        guard phase != .importing else { return }
        if let previous = previousImport {
            phase = .confirmRepeat(previous: previous)
            return
        }
        await run()
    }

    /// Imports again after the user confirmed. A no-op while importing.
    public func confirmRepeat() async {
        guard phase != .importing else { return }
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
            previousImport = try? store.lastImport(source: .arc)
            revision.bump()
            phase = .finished(ArcImportSummary(report: report))
        case .failure(let error):
            phase = .failed(ArcImportCopy.errorMessage(for: error))
        }
    }
}
