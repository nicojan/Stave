import Foundation

/// Launch arguments for by-hand checks on throwaway synthetic data. They exist only in Debug builds: in Release `current` has every
/// field nil/false, so a stray argument can never redirect a shipped app's data folder or seed anything.
struct DebugLaunchOptions: Equatable {
    /// `-StaveDataDirectory <path>`: the data folder to open instead of the Application Support one.
    var dataDirectory: URL?
    /// `-StaveArcHome <path>`: the folder that stands in for the user's home when looking for Arc's files.
    var arcHome: URL?
    /// `-StaveSeedSample`: write `SampleOrganization` into a store that has no tabs.
    var seedSample: Bool

    static let none = DebugLaunchOptions(dataDirectory: nil, arcHome: nil, seedSample: false)

    static var current: DebugLaunchOptions {
        #if DEBUG
        parse(ProcessInfo.processInfo.arguments)
        #else
        none
        #endif
    }

    #if DEBUG
    static func parse(_ arguments: [String]) -> DebugLaunchOptions {
        DebugLaunchOptions(
            dataDirectory: value(after: "-StaveDataDirectory", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) },
            arcHome: value(after: "-StaveArcHome", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) },
            seedSample: arguments.contains("-StaveSeedSample")
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.isEmpty || value.hasPrefix("-") ? nil : value
    }
    #endif
}
