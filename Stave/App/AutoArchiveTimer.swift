import Foundation
import StaveCore

/// Archives idle tabs (decision 34, question 27): a check at launch (after the saved windows are restored) and one every 15 minutes while
/// Stave runs. Which tabs qualify is `AutoArchivePolicy`'s call, and the launch ordering is `AutoArchiveSchedule`'s; this type gathers what
/// only the app knows (which tabs are shown, which are busy) and tears the archived tabs' pages down the way `closeTab` does.
@MainActor
final class AutoArchiveTimer {
    private let environment: AppEnvironment
    private let controllers: () -> [BrowserWindowController]
    private lazy var schedule = AutoArchiveSchedule { [weak self] in self?.startCheck() }
    private var tick: Task<Void, Never>?
    /// One check at a time: a media check can take a moment, and a second check over the same tabs would only repeat it.
    private var checkTask: Task<Void, Never>?
    /// Skips a check after the wall clock jumped, and starts over from the new reading.
    private var clockGuard = ClockJumpGuard()

    init(environment: AppEnvironment, controllers: @escaping () -> [BrowserWindowController]) {
        self.environment = environment
        self.controllers = controllers
    }

    /// Asks for the launch check, which runs once `launchCompleted()` is called, and starts the 15-minute tick.
    func start() {
        schedule.requestCheck()
        tick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AutoArchiveSchedule.interval))
                guard !Task.isCancelled else { return }
                self?.schedule.requestCheck()
            }
        }
    }

    /// The saved windows are open and their selected tabs are registered: a waiting check may run.
    func launchCompleted() { schedule.launchCompleted() }

    func stop() {
        tick?.cancel()
        checkTask?.cancel()
    }

    private func startCheck() {
        guard checkTask == nil else { return }
        checkTask = Task { @MainActor [weak self] in
            await self?.check()
            self?.checkTask = nil
        }
    }

    /// Private windows have no store tabs and are never part of this: only the profiles that normal windows show are checked.
    private func check() async {
        // Every tick reads both clocks, whatever the setting says, so the reference is never old.
        let now = Date()
        if case .skip(let reason) = environment.store.checkClock(&clockGuard, wall: now, instant: ContinuousClock.now) {
            NSLog("Stave: the clock jumped (\(reason)); skipping this idle-tab check")
            return
        }
        let store = environment.store
        let limit: AutoArchiveAfter
        do { limit = try store.setting(SettingKeys.autoArchiveAfter) } catch {
            NSLog("Stave: could not read the idle-tab setting: \(error)")
            return
        }
        guard limit != .never else { return }
        var profileIDs: [UUID] = []
        for controller in controllers() {
            let id = controller.model.snapshot.profile.id
            if !profileIDs.contains(id) { profileIDs.append(id) }
        }
        var archived: [UUID] = []
        for profileID in profileIDs {
            guard !Task.isCancelled else { return }
            archived += await archiveIdle(profileID: profileID, limit: limit, now: now)
        }
        guard !archived.isEmpty else { return }
        environment.revision.bump() // every window re-reads its sidebar
    }

    /// `now` is read once per check and used for both passes: a tab whose limit passes during the media checks was not checked, so it is
    /// not archived this round (and `among` keeps it out even if something else made it idle meanwhile).
    private func archiveIdle(profileID: UUID, limit: AutoArchiveAfter, now: Date) async -> [UUID] {
        let store = environment.store
        do {
            // First pass, with nothing marked busy: the tabs that are idle and not shown. Only these are worth a media check.
            let provisional = Set(try store.idleTabIDs(profileID: profileID, now: now, limit: limit, shown: environment.livePages.shownTabs, busy: []))
            guard !provisional.isEmpty else { return [] }
            // A download runs per profile, not per tab: while one runs, none of the profile's tabs is archived.
            guard !environment.downloads.hasRunning(owner: .profile(profileID)) else { return [] }
            let busy = await environment.pageHost.busyTabs(among: provisional)
            return try archiveNow(profileID: profileID, now: now, busy: busy, among: provisional)
        } catch {
            NSLog("Stave: could not archive idle tabs: \(error)")
            return []
        }
    }

    /// Everything from the last busy check to the archive write happens in one turn, with `shown`, the dialogs, the pop-ups, the waiting
    /// download questions and the download list read again: a tab shown or made busy during the media checks is kept.
    private func archiveNow(profileID: UUID, now: Date, busy: Set<UUID>, among provisional: Set<UUID>) throws -> [UUID] {
        let store = environment.store
        let host = environment.pageHost
        // The limit is read again in this same turn as the archive: switching to Never during the media checks stops this check.
        let limit = try store.setting(SettingKeys.autoArchiveAfter)
        guard limit != .never else { return [] }
        guard !environment.downloads.hasRunning(owner: .profile(profileID)) else { return [] }
        let waiting = provisional.filter { environment.pageQuestions.hasSeveralDownloadsQuestion(tabID: $0) }
        let allBusy = busy.union(host.holdingDialogsOrPopups(among: provisional)).union(waiting)
        let shown = environment.livePages.shownTabs
        let toArchive = try store.idleTabIDs(profileID: profileID, now: now, limit: limit, shown: shown, busy: allBusy, among: provisional)
        // As `close` does: a title still waiting in a page is written first, because the archive keeps the title as last written.
        for id in toArchive { host.flushTitle(id) }
        let archived = try store.archiveIdleTabIDs(profileID: profileID, now: now, limit: limit, shown: shown, busy: allBusy, among: provisional)
        // And as `tabGone` does: the claims go, then every window drops the page, its questions and pop-ups.
        for id in archived {
            environment.livePages.tabRemoved(id)
            for controller in controllers() { controller.tabClosed(id) }
            environment.pageHost.close(id) // also when no window is left to do it (a no-op after `tabClosed`)
        }
        return archived
    }
}
