import Foundation
import StaveCore

/// Launch arguments for by-hand checks on throwaway synthetic data. They exist only in Debug builds: in Release `current` has every
/// field nil/false, so a stray argument can never redirect a shipped app's data folder or seed anything.
/// The parsing is `LaunchArguments` in StaveCore. A flag that is present but unusable makes `current` throw (the app then refuses to start).
struct DebugLaunchOptions: Equatable {
    /// `-StaveDataDirectory <path>`: the data folder to open instead of the Application Support one.
    var dataDirectory: URL?
    /// `-StaveArcHome <path>`: the folder that stands in for the user's home when looking for Arc's files.
    var arcHome: URL?
    /// `-StaveSeedSample`: write `SampleOrganization` into a store that has no tabs.
    var seedSample: Bool

    static let none = DebugLaunchOptions(dataDirectory: nil, arcHome: nil, seedSample: false)

    static var current: DebugLaunchOptions {
        get throws {
            #if DEBUG
            let parsed = try LaunchArguments.parse(ProcessInfo.processInfo.arguments)
            return DebugLaunchOptions(
                dataDirectory: parsed.dataDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) },
                arcHome: parsed.arcHome.map { URL(fileURLWithPath: $0, isDirectory: true) },
                seedSample: parsed.seedSample
            )
            #else
            return none
            #endif
        }
    }
}
