import Foundation
import Network

/// A real HTTP listener on 127.0.0.1 for tests that must see the request header WebKit sends (`navigator.userAgent` can't show it).
/// Each request is recorded; `/hang…` is never answered (a load that stays pending); `/link` answers a page with a link to
/// `http://localhost:<port>/next` (another host, same listener); every other path answers a small page.
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable, Equatable {
        let path: String
        let host: String?
        let userAgent: String?
        let referer: String?
        let secFetchSite: String?
    }

    /// Why the listener never became ready (a `.waiting` or `.cancelled` state, which would otherwise leave the test hanging).
    struct NotReady: Error, CustomStringConvertible {
        let description: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    /// Starts listening and returns once the port is known.
    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        port = try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: gate.resume(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): gate.resume(.failure(error))
                case .waiting(let error): gate.resume(.failure(NotReady(description: "listener is waiting: \(error)")))
                case .cancelled: gate.resume(.failure(NotReady(description: "listener was cancelled before it was ready")))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = held
        held = []
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    func url(host: String = "127.0.0.1", _ path: String) -> String { "http://\(host):\(port)\(path)" }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(for path: String) -> [Request] { requests.filter { $0.path == path } }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffered: Data())
    }

    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var all = buffered
            if let data { all.append(data) }
            if let end = all.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(connection, head: String(decoding: all[..<end.lowerBound], as: UTF8.self))
            } else if error == nil, !complete {
                self.read(connection, buffered: all)
            } else {
                connection.cancel()
            }
        }
    }

    private func answer(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        func header(_ name: String) -> String? {
            lines.dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        lock.lock()
        recorded.append(Request(path: path, host: header("Host"), userAgent: header("User-Agent"), referer: header("Referer"), secFetchSite: header("Sec-Fetch-Site")))
        let hangs = path.hasPrefix("/hang")
        if hangs { held.append(connection) }
        lock.unlock()
        if hangs { return }
        let body = path == "/link"
            ? "<title>link</title><a id=\"go\" href=\"http://localhost:\(port)/next\">go</a>"
            : "<title>ok</title>ok"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Resumes a continuation once, whichever state callback comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }

    func resume(_ result: Result<UInt16, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
