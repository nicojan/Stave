import Foundation
import Observation

/// The one sidebar width of the whole app: every window reads and writes it, and it is saved 0.5 s after the last change.
@MainActor @Observable
public final class SidebarWidthModel {
    public static let range: ClosedRange<Double> = 200...400
    public static let step: Double = 10

    public static func clamp(_ width: Double) -> Double {
        width.isFinite ? min(max(width, range.lowerBound), range.upperBound) : SettingKeys.sidebarWidth.defaultValue
    }

    public private(set) var width: Double

    @ObservationIgnored private let store: OrganizationStore
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var storedWidth: Double
    /// The pending delayed save. Internal so tests can await it instead of sleeping; a cancelled task finishes at once.
    @ObservationIgnored private(set) var saveTask: Task<Void, Never>?
    /// How many times the width was written to the store; lets a test prove a save did not happen.
    @ObservationIgnored private(set) var writeCount = 0
    /// Called when the debounced save fails; the width stays as set.
    @ObservationIgnored public var onSaveError: (@MainActor (Error) -> Void)?

    public init(store: OrganizationStore, saveDelay: Duration = .milliseconds(500)) {
        self.store = store
        self.saveDelay = saveDelay
        let stored = (try? store.setting(SettingKeys.sidebarWidth)) ?? SettingKeys.sidebarWidth.defaultValue
        let clamped = Self.clamp(stored)
        width = clamped
        storedWidth = clamped
    }

    /// Sets the (clamped) width. Every change cancels the pending save and starts a new delay, whether or not the width differs from the stored one.
    public func set(_ newWidth: Double) {
        width = Self.clamp(newWidth)
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveIfChanged()
        }
    }

    public func nudge(by delta: Double) { set(width + delta) }

    /// Writes the width now when it differs from the stored one (used at quit as well as by the delay).
    public func saveIfChanged() {
        guard width != storedWidth else { return }
        do {
            try store.setSetting(SettingKeys.sidebarWidth, width)
            storedWidth = width
            writeCount += 1
        } catch {
            onSaveError?(error)
        }
    }
}
