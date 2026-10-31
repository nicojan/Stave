import Foundation

/// The Debug launch flags, parsed. A flag that is absent is nil; a flag that is present but unusable throws, so the app can refuse to start
/// instead of quietly using the real folders.
public struct LaunchArguments: Equatable, Sendable {
    public static let dataDirectoryFlag = "-StaveDataDirectory"
    public static let arcHomeFlag = "-StaveArcHome"
    public static let seedSampleFlag = "-StaveSeedSample"

    public enum Failure: Error, Equatable, Sendable {
        /// The flag has no value, a value that starts with "-", or a path that is not absolute.
        case unusable(flag: String)
    }

    public var dataDirectory: String?
    public var arcHome: String?
    public var seedSample: Bool

    public static let none = LaunchArguments(dataDirectory: nil, arcHome: nil, seedSample: false)

    public static func parse(_ arguments: [String]) throws -> LaunchArguments {
        LaunchArguments(
            dataDirectory: try path(after: dataDirectoryFlag, in: arguments),
            arcHome: try path(after: arcHomeFlag, in: arguments),
            seedSample: arguments.contains(seedSampleFlag)
        )
    }

    private static func path(after flag: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard arguments.indices.contains(index + 1) else { throw Failure.unusable(flag: flag) }
        let value = arguments[index + 1]
        guard value.hasPrefix("/") else { throw Failure.unusable(flag: flag) }
        return value
    }
}
