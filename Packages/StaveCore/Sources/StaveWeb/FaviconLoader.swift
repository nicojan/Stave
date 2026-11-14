import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches the favicon a page reported, without cookies, and keeps a scaled copy (plan 5 decision 10, Review Focus 5).
///
/// The fetch goes through an ephemeral session that has no cookie store, credential store or URL cache; only `http` and `https` are
/// fetched and a redirect to any other scheme is refused. The body is capped at `maxBytes` and the whole fetch at `timeout`. The image is
/// decoded and scaled off the main actor to 32 x 32 pt @2x; an image wider or taller than `FaviconLoader.maxPixelSide` is refused before
/// it is scaled. The PNG is kept in memory and, when `cacheFolder` is set, in `<cacheFolder>/<sha256 of URL>.png`; with no folder (a
/// private window) nothing is written. A favicon is outside data: anything strange makes the load return nil, and the row keeps its
/// fallback.
@MainActor
public final class FaviconLoader {
    /// The widest or tallest image accepted, in pixels.
    public nonisolated static let maxPixelSide = 1024
    /// The stored image's side in pixels: 32 pt at 2x.
    public nonisolated static let pixelSide = 64
    /// The shown image's side in points.
    public nonisolated static let pointSide: CGFloat = 32
    /// A reported address longer than this is not fetched.
    nonisolated static let maxURLLength = 8192

    /// The folder under the data folder that holds the cache.
    public nonisolated static let folderName = "Favicons"

    /// `<data folder>/Favicons`: one flat cache for every profile (decision 10).
    public nonisolated static func cacheFolder(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Where the PNGs are kept; nil keeps them in memory only.
    public nonisolated let cacheFolder: URL?
    private let session: URLSession
    private let maxBytes: Int
    private let maxFiles: Int
    private let timeout: TimeInterval
    /// Loaded images by the hash of their address.
    private var images: [String: NSImage] = [:]
    /// Addresses `image(for:)` already looked for on disk and didn't find, so a row redrawing doesn't read the disk again; `load(_:)` puts
    /// what it fetches in `images`.
    private var notOnDisk: Set<String> = []
    /// Addresses that failed this run; tried again after a relaunch.
    private var failed: Set<String> = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Decodes and scales a body to PNG data. A test seam; it is called from the main actor and, being nonisolated, runs off it.
    var decode: @Sendable (Data) async -> Data? = { FaviconLoader.scaledPNG($0) }

    /// How long a whole fetch may take, in seconds.
    public nonisolated static let defaultTimeout: TimeInterval = 10

    /// `configuration` should be `FaviconLoader.configuration()`; tests add only a `URLProtocol` stub to it. The loader makes its own
    /// session from a copy.
    public convenience init(
        cacheFolder: URL?, configuration: URLSessionConfiguration = FaviconLoader.configuration(),
        maxBytes: Int = 524_288, maxFiles: Int = 2000
    ) {
        self.init(cacheFolder: cacheFolder, configuration: configuration, maxBytes: maxBytes, maxFiles: maxFiles, timeout: Self.defaultTimeout)
    }

    /// The same with a shorter `timeout`, for tests of a slow server.
    init(cacheFolder: URL?, configuration: URLSessionConfiguration, maxBytes: Int, maxFiles: Int, timeout: TimeInterval) {
        self.cacheFolder = cacheFolder
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        self.timeout = timeout
        let copy = (configuration.copy() as? URLSessionConfiguration) ?? FaviconLoader.configuration()
        copy.timeoutIntervalForRequest = timeout
        copy.timeoutIntervalForResource = timeout
        session = URLSession(configuration: copy, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// An ephemeral configuration with no cookies, no credentials and no URL cache, so a favicon request never tells a site who asks.
    public nonisolated static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// The cached image for an address: from memory, else from the cache folder (a 64 px PNG, so a row shows it on first paint after a
    /// relaunch). Never touches the network; a miss on disk is remembered until `load(_:)` brings the image.
    public func image(for faviconURL: String?) -> NSImage? {
        guard let faviconURL, let key = Self.key(for: faviconURL) else { return nil }
        if let image = images[key] { return image }
        guard let cacheFolder, !notOnDisk.contains(key) else { return nil }
        guard let png = Self.readCachedNow(cacheFolder.appendingPathComponent(key + ".png")), let image = Self.image(png) else {
            notOnDisk.insert(key)
            return nil
        }
        keep(image, key: key)
        return image
    }

    /// The image for an address: from memory, else the cache folder, else the network. Nil when the address isn't `http`/`https` or
    /// anything along the way fails; a failed address is not tried again this run.
    public func load(_ faviconURL: String) async -> NSImage? {
        guard let key = Self.key(for: faviconURL), let url = URL(string: faviconURL) else { return nil }
        if let image = images[key] { return image }
        if failed.contains(key) { return nil }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await self.fetchAndKeep(url, key: key) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { keep(image, key: key) } else { failed.insert(key) }
        return image
    }

    /// Removes the cache's own files beyond `maxFiles`, least recently used first. Files that aren't the cache's own are left alone.
    public func prune() {
        guard let cacheFolder else { return }
        Self.prune(folder: cacheFolder, keeping: maxFiles)
    }

    private func keep(_ image: NSImage, key: String) {
        if images.count >= maxFiles, let any = images.keys.first { images[any] = nil }
        images[key] = image
    }

    private func fetchAndKeep(_ url: URL, key: String) async -> NSImage? {
        let file = cacheFolder?.appendingPathComponent(key + ".png")
        if let file, let png = await Self.readCached(file) { return Self.image(png) }
        guard let body = await Self.fetch(url, session: session, maxBytes: maxBytes, timeout: timeout),
              let png = await decode(body) else { return nil }
        if let cacheFolder, let file { await Self.store(png, at: file, in: cacheFolder, keeping: maxFiles) }
        return Self.image(png)
    }

    private static func image(_ png: Data) -> NSImage? {
        guard let image = NSImage(data: png) else { return nil }
        image.size = NSSize(width: pointSide, height: pointSide)
        return image
    }
}

// MARK: - Keys and files

extension FaviconLoader {
    /// The SHA-256 of the address, in lowercase hex, when it is an `http` or `https` URL with a host; nil otherwise.
    nonisolated static func key(for faviconURL: String) -> String? {
        guard faviconURL.utf8.count <= maxURLLength, let url = URL(string: faviconURL),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return SHA256.hash(data: Data(faviconURL.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True for `<64 lowercase hex>.png`, the only names the cache writes or prunes.
    nonisolated static func isOwnFile(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        let stem = name.dropLast(4)
        return stem.count == 64 && stem.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A cached PNG, its use time refreshed so pruning keeps it; nil when it is missing or unreadable.
    nonisolated static func readCached(_ file: URL) async -> Data? { readCachedNow(file) }

    /// The same, read on the caller's thread.
    nonisolated static func readCachedNow(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    nonisolated static func store(_ png: Data, at file: URL, in folder: URL, keeping maxFiles: Int) async {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
        } catch {
            NSLog("Stave: could not cache a favicon: \(error)")
            return
        }
        prune(folder: folder, keeping: maxFiles)
    }

    nonisolated static func prune(folder: URL, keeping maxFiles: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let own = entries.filter { isOwnFile($0.lastPathComponent) }
        guard own.count > maxFiles else { return }
        let dated = own.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(maxFiles) {
            do { try FileManager.default.removeItem(at: url) } catch { NSLog("Stave: could not prune a favicon: \(error)") }
        }
    }
}

// MARK: - Fetching

extension FaviconLoader {
    /// The body, or nil when the fetch fails, isn't a 2xx `http`/`https` response, goes past `maxBytes` or takes longer than `timeout`.
    nonisolated static func fetch(_ url: URL, session: URLSession, maxBytes: Int, timeout: TimeInterval) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await download(url, session: session, maxBytes: maxBytes) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func download(_ url: URL, session: URLSession, maxBytes: Int) async -> Data? {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let scheme = http.url?.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  http.expectedContentLength <= Int64(maxBytes) else {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            data.reserveCapacity(http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 16_384)
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes {
                    bytes.task.cancel()
                    return nil
                }
            }
            return data
        } catch {
            return nil
        }
    }
}

// MARK: - Decoding

extension FaviconLoader {
    /// The image scaled to fit `pixelSide` x `pixelSide`, as PNG data. Nil when the data isn't an image ImageIO reads, or every frame
    /// (an `.ico` holds several) is wider or taller than `maxPixelSide`; the check reads only the header, before any pixel is decoded.
    public nonisolated static func scaledPNG(_ data: Data) -> Data? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetType(source) != nil,
              let index = bestFrame(in: source),
              let image = CGImageSourceCreateImageAtIndex(source, index, options),
              image.width <= maxPixelSide, image.height <= maxPixelSide else { return nil }
        return render(image)
    }

    /// The smallest frame at least `pixelSide` on its short side, else the largest; only frames within `maxPixelSide`.
    private nonisolated static func bestFrame(in source: CGImageSource) -> Int? {
        let frames = (0..<CGImageSourceGetCount(source)).compactMap { index -> (index: Int, width: Int, height: Int)? in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= maxPixelSide, height <= maxPixelSide else { return nil }
            return (index, width, height)
        }
        let bigEnough = frames.filter { min($0.width, $0.height) >= pixelSide }
        if let smallest = bigEnough.min(by: { $0.width * $0.height < $1.width * $1.height }) { return smallest.index }
        return frames.max(by: { $0.width * $0.height < $1.width * $1.height })?.index
    }

    private nonisolated static func render(_ image: CGImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        let side = CGFloat(pixelSide)
        let scale = min(side / CGFloat(image.width), side / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Refuses a redirect to anything but `http` or `https`, so a favicon can never be read from `file:` or another scheme.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let scheme = request.url?.scheme?.lowercased()
        completionHandler(scheme == "https" || scheme == "http" ? request : nil)
    }
}
