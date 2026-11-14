import AppKit
import CryptoKit
import Foundation
import ImageIO
import Observation
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import StaveWeb

/// Favicons through the production session configuration with a `URLProtocol` stub added, so no test touches the network (decision 10,
/// Review Focus 5). Every test uses its own host, so the stub's behaviours never collide when tests run in parallel.
@MainActor
struct FaviconLoaderTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FaviconLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The production configuration with only the stub added.
    private func configuration() -> URLSessionConfiguration {
        let configuration = FaviconLoader.configuration()
        configuration.protocolClasses = [FaviconStub.self]
        return configuration
    }

    private func loader(_ folder: URL?, maxFiles: Int = 2000, timeout: TimeInterval = 10) -> FaviconLoader {
        FaviconLoader(cacheFolder: folder, configuration: configuration(), maxBytes: 524_288, maxFiles: maxFiles, timeout: timeout)
    }

    private func cacheFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The control: a plain 48 x 48 PNG is fetched, decoded and cached, so a nil elsewhere means the refusal, not a broken pipeline.
    @Test func plainIconLoads() async throws {
        let url = "https://plain.example.com/favicon.png"
        FaviconStub.set("plain.example.com", .body(FaviconFixtures.png(width: 48, height: 48)))
        let loader = loader(nil)
        let image = try #require(await loader.load(url))
        #expect(image.size == NSSize(width: 32, height: 32))
        #expect(loader.image(for: url) != nil)
    }

    /// A 2 MB body is refused and its transfer is cancelled at the cap, before the stub has sent it all; a declared length over the cap
    /// is refused at the response.
    @Test func faviconBodyCapped() async throws {
        let total = 2 * 1024 * 1024
        FaviconStub.set("big.example.com", .paced(Data(repeating: 0x41, count: total), chunk: 64 * 1024, every: 0.01, declareLength: false))
        let loader = loader(nil)
        #expect(await loader.load("https://big.example.com/favicon.ico") == nil)
        let sent = FaviconStub.bytesSent(to: "big.example.com")
        #expect(sent > 0) // the transfer really started
        #expect(sent < total, "the stub sent \(sent) of \(total) bytes")

        FaviconStub.set("declared.example.com", .paced(Data(repeating: 0x41, count: total), chunk: 64 * 1024, every: 0.01, declareLength: true))
        #expect(await loader.load("https://declared.example.com/favicon.ico") == nil)
        #expect(FaviconStub.bytesSent(to: "declared.example.com") < total)
    }

    /// A redirect to a `file:` URL is never followed, even to a real image on disk that would otherwise load.
    @Test func faviconRedirectToFileRefused() async throws {
        let folder = try folder()
        let target = folder.appendingPathComponent("icon.png")
        try FaviconFixtures.png(width: 32, height: 32).write(to: target)
        FaviconStub.set("redirect.example.com", .redirect(to: target))
        let loader = loader(nil)
        #expect(await loader.load("https://redirect.example.com/favicon.ico") == nil)
        #expect(FaviconStub.requests(to: "redirect.example.com").count == 1)
        // The control: a redirect to another https address is followed and loads.
        FaviconStub.set("hop.example.com", .redirect(to: URL(string: "https://landing.example.com/icon.png")!))
        FaviconStub.set("landing.example.com", .body(FaviconFixtures.png(width: 32, height: 32)))
        #expect(await loader.load("https://hop.example.com/favicon.ico") != nil)
        // The guard itself refuses every scheme but http and https.
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://redirect.example.com/")!)
        let reply = HTTPURLResponse(url: URL(string: "https://redirect.example.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for (address, allowed) in [(target.absoluteString, false), ("data:image/png;base64,AAAA", false), ("ftp://example.com/i.ico", false),
                                   ("https://example.org/i.ico", true), ("http://example.org/i.ico", true)] {
            let decided = Mutex<URLRequest??>(nil)
            RedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: reply, newRequest: URLRequest(url: URL(string: address)!)) { next in
                decided.withLock { $0 = .some(next) }
            }
            #expect(decided.withLock { $0 }.map { $0 != nil } == allowed, "\(address)")
        }
        session.invalidateAndCancel()
        // A reported address that is not http or https is never fetched at all.
        #expect(await loader.load(target.absoluteString) == nil)
        #expect(await loader.load("data:image/png;base64,AAAA") == nil)
    }

    /// The configuration keeps no cookies, credentials or URL cache, and a cookie set in the shared store never reaches the request.
    @Test func faviconRequestCarriesNoCookies() async throws {
        let production = FaviconLoader.configuration()
        #expect(production.httpCookieStorage == nil)
        #expect(production.httpShouldSetCookies == false)
        #expect(production.urlCredentialStorage == nil)
        #expect(production.urlCache == nil)

        let host = "cookie.example.com"
        let cookie = try #require(HTTPCookie(properties: [
            .name: "favicontest", .value: "1", .domain: host, .path: "/", .expires: Date().addingTimeInterval(600),
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        FaviconStub.set(host, .body(FaviconFixtures.png(width: 16, height: 16)))
        #expect(await loader(nil).load("https://\(host)/favicon.ico") != nil)
        let seen = try #require(FaviconStub.requests(to: host).first)
        #expect(seen.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(seen.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// HTML served as an icon decodes to nothing, is not cached, and leaves the row on its fallback.
    @Test func htmlBodyIsNotAnImage() async throws {
        let folder = try folder()
        let url = "https://html.example.com/favicon.ico"
        FaviconStub.set("html.example.com", .body(Data("<!doctype html><html><body>Not an icon</body></html>".utf8), contentType: "image/png"))
        let loader = loader(folder)
        #expect(await loader.load(url) == nil)
        #expect(loader.image(for: url) == nil)
        #expect(try cacheFiles(in: folder).isEmpty)
    }

    /// A 1 x 100,000 PNG, well under the byte cap, is refused before it is scaled.
    @Test func faviconHugeDimensionsRefused() async throws {
        let tall = FaviconFixtures.png(width: 1, height: 100_000)
        #expect(tall.count < 524_288)
        FaviconStub.set("tall.example.com", .body(tall))
        #expect(await loader(nil).load("https://tall.example.com/favicon.png") == nil)
        #expect(FaviconLoader.scaledPNG(tall) == nil)
        #expect(FaviconLoader.scaledPNG(FaviconFixtures.png(width: 1024, height: 1024)) != nil)
    }

    /// A server that trickles one byte at a time is given up on at the timeout. Its body is a real icon, so without the timeout the load
    /// would end, much later, with an image.
    @Test func faviconSlowTrickleTimesOut() async throws {
        let icon = FaviconFixtures.png(width: 16, height: 16)
        FaviconStub.set("slow.example.com", .paced(icon, chunk: 1, every: 0.25, declareLength: true))
        let started = ContinuousClock.now
        #expect(await loader(nil, timeout: 1).load("https://slow.example.com/favicon.png") == nil)
        // Bounded by the whole trickle, not a fixed time: a loaded CI runner can starve the 1 s timeout for several seconds, but
        // ending before the last byte could have arrived still proves the load gave up rather than finished.
        #expect(ContinuousClock.now - started < .seconds(Double(icon.count) * 0.25))
        #expect(FaviconStub.bytesSent(to: "slow.example.com") > 0) // the trickle really started
    }

    /// The scaled PNG is stored as `<sha256 of the URL>.png`, and a new loader on the same folder serves it without asking the network.
    @Test func cachedOnDiskByHash() async throws {
        let folder = try folder()
        let url = "https://disk.example.com/favicon.png"
        FaviconStub.set("disk.example.com", .body(FaviconFixtures.png(width: 64, height: 64)))
        #expect(await loader(folder).load(url) != nil)
        #expect(try cacheFiles(in: folder) == [Self.sha256(url) + ".png"])
        let stored = try Data(contentsOf: folder.appendingPathComponent(Self.sha256(url) + ".png"))
        #expect(FaviconFixtures.pixelSize(stored) == CGSize(width: 64, height: 64))

        FaviconStub.set("disk.example.com", .fail)
        let relaunched = loader(folder)
        // Cached only (decision 10): the relaunched loader's first `image(for:)` reads the disk, so a row shows the icon on first paint.
        let atOnce = try #require(relaunched.image(for: url))
        #expect(atOnce.size == NSSize(width: 32, height: 32))
        #expect(await relaunched.load(url) != nil)
        #expect(relaunched.image(for: url) != nil)
        #expect(FaviconStub.requests(to: "disk.example.com").count == 1)
    }

    /// Pruning keeps the newest-used files up to the limit and never touches a file that isn't the cache's own.
    @Test func pruneKeepsNewest() throws {
        let folder = try folder()
        let names = (0..<5).map { Self.sha256("https://prune.example.com/\($0).ico") + ".png" }
        for (index, name) in names.enumerated() {
            let file = folder.appendingPathComponent(name)
            try Data([0x1]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60)], ofItemAtPath: file.path)
        }
        let strangers = ["notes.txt", "stave.sqlite", "ABC.png"]
        for name in strangers {
            let file = folder.appendingPathComponent(name)
            try Data([0x2]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
        }
        loader(folder, maxFiles: 3).prune()
        #expect(try cacheFiles(in: folder) == (Array(names.suffix(3)) + strangers).sorted())
    }

    /// A private window's loader (no folder) keeps the image in memory and writes nothing: another loader can't find it.
    @Test func privateLoaderWritesNoFiles() async throws {
        let url = "https://private.example.com/favicon.png"
        FaviconStub.set("private.example.com", .body(FaviconFixtures.png(width: 32, height: 32)))
        let first = loader(nil)
        #expect(await first.load(url) != nil)
        #expect(first.image(for: url) != nil)
        FaviconStub.set("private.example.com", .fail)
        let second = loader(nil)
        #expect(await second.load(url) == nil)
        #expect(FaviconLoader.configuration().urlCache == nil)
    }

    /// The decode runs off the main thread, and the main actor keeps running while a slow decode is under way.
    @Test func decodeOffMain() async throws {
        FaviconStub.set("decode.example.com", .body(FaviconFixtures.png(width: 32, height: 32)))
        let probe = DecodeProbe()
        let loader = loader(nil)
        loader.decode = { data in probe.slowDecode(data) }
        let load = Task { await loader.load("https://decode.example.com/favicon.png") }
        let deadline = ContinuousClock.now + .seconds(60)
        while !probe.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(probe.started)
        // The decode is blocked until this main-actor code releases it, so reaching here with it unfinished proves the main actor
        // keeps running during a decode (a decode on the main thread would block this loop until its 60 s gate timed out).
        let tickedDuringDecode = !probe.finished
        probe.release()
        #expect(tickedDuringDecode)
        #expect(await load.value != nil)
        #expect(probe.ranOnMain == false)
    }

    /// Decision 10: one flat cache, `<data folder>/Favicons/<sha256 of URL>.png`, shared by every profile.
    @Test func cacheFolderIsFlatUnderTheDataFolder() {
        let data = URL(fileURLWithPath: "/private/tmp/stave-favicon-test/data", isDirectory: true)
        #expect(FaviconLoader.cacheFolder(dataDirectory: data) == data.appendingPathComponent("Favicons", isDirectory: true))
    }

    /// The brief's interface: a plain `@MainActor` class (rows keep the image they loaded in their own state), not `@Observable`.
    @Test func loaderIsNotObservable() {
        #expect(!((loader(nil) as Any) is any Observable))
    }
}

/// What the slow decode saw, written off the main actor.
private final class DecodeProbe: Sendable {
    private let state = Mutex((started: false, finished: false, onMain: false))
    func start(onMain: Bool) { state.withLock { $0.started = true; $0.onMain = onMain } }
    func finish() { state.withLock { $0.finished = true } }
    var started: Bool { state.withLock { $0.started } }
    var finished: Bool { state.withLock { $0.finished } }
    var ranOnMain: Bool { state.withLock { $0.onMain } }

    private let gate = DispatchSemaphore(value: 0)
    func release() { gate.signal() }

    /// A decode that blocks its thread until the test releases it (at most 60 s), as a large image would.
    func slowDecode(_ data: Data) -> Data? {
        start(onMain: Thread.isMainThread)
        _ = gate.wait(timeout: .now() + 60)
        finish()
        return FaviconLoader.scaledPNG(data)
    }
}

enum FaviconFixtures {
    /// A solid PNG of the given pixel size, made in memory.
    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// Answers favicon requests by host from a table the tests fill, and records what it was asked and how much it sent.
final class FaviconStub: URLProtocol, @unchecked Sendable {
    enum Behaviour: Sendable {
        case body(Data, contentType: String = "image/png")
        case paced(Data, chunk: Int, every: TimeInterval, declareLength: Bool)
        case redirect(to: URL)
        case fail
    }

    private struct Table {
        var behaviours: [String: Behaviour] = [:]
        var requests: [String: [URLRequest]] = [:]
        var sent: [String: Int] = [:]
    }

    private static let table = Mutex(Table())
    private let stopped = Mutex(false)

    static func set(_ host: String, _ behaviour: Behaviour) { table.withLock { $0.behaviours[host] = behaviour } }
    static func requests(to host: String) -> [URLRequest] { table.withLock { $0.requests[host] ?? [] } }
    static func bytesSent(to host: String) -> Int { table.withLock { $0.sent[host] ?? 0 } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" || request.url?.scheme == "http" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        let behaviour = Self.table.withLock { table -> Behaviour in
            table.requests[host, default: []].append(request)
            return table.behaviours[host] ?? .fail
        }
        switch behaviour {
        case .body(let data, let type):
            respond(url, status: 200, headers: ["Content-Type": type, "Content-Length": "\(data.count)"])
            send(data, host: host)
            client?.urlProtocolDidFinishLoading(self)
        case .paced(let data, let chunk, let every, let declare):
            var headers = ["Content-Type": "image/png"]
            if declare { headers["Content-Length"] = "\(data.count)" }
            respond(url, status: 200, headers: headers)
            pace(data, from: 0, chunk: chunk, every: every, host: host)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            // The loading system asks the session's delegate. A followed redirect stops this protocol and starts the new request; a
            // refused one leaves the protocol to end the task with the redirect response itself, as the HTTP protocol does.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                guard !stopped.withLock({ $0 }) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }

    private func respond(_ url: URL, status: Int, headers: [String: String]) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    private func send(_ data: Data, host: String) {
        Self.table.withLock { $0.sent[host, default: 0] += data.count }
        client?.urlProtocol(self, didLoad: data)
    }

    private func pace(_ data: Data, from offset: Int, chunk: Int, every: TimeInterval, host: String) {
        guard !stopped.withLock({ $0 }) else { return }
        guard offset < data.count else { client?.urlProtocolDidFinishLoading(self); return }
        let end = min(offset + chunk, data.count)
        send(data.subdata(in: offset..<end), host: host)
        DispatchQueue.global().asyncAfter(deadline: .now() + every) { [self] in
            pace(data, from: end, chunk: chunk, every: every, host: host)
        }
    }
}
