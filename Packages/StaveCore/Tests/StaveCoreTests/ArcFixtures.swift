import Foundation

enum ArcFixtureError: Error { case missing(String) }

/// Loads `Fixtures/arc/<name>.json` from the test bundle.
func arcFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/arc") else {
        throw ArcFixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}
