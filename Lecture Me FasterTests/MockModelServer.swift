import Foundation

/// A fake model server inside the test process, so tests never touch the network or a paid service.
///
/// Requests to a host passed to `start(host:responder:)` are answered here; all other requests are
/// untouched. By default it answers like an OpenAI-compatible chat server, streaming "Reply N" for the
/// Nth chat request; a `responder` can answer some requests itself (for example a model list), and those
/// don't count as chat requests. Each host has its own state, so suites using different hosts can run at
/// the same time.
final class MockModelServer: URLProtocol, @unchecked Sendable {
    static let host = "mock-model.lecture-me-faster.test"

    /// Answers a request with a status and a JSON body, or nil to fall back to the chat reply.
    typealias Responder = @Sendable (URLRequest) -> (status: Int, body: String)?
    /// Answers a chat request with the text to stream back, chosen from the request's body; nil falls back.
    typealias ChatResponder = @Sendable (_ body: String) -> String?

    /// Every request a host received.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String] = []
        private var urls: [URL] = []
        private var chatBodies: [String] = []
        var requests: [String] { lock.withLock { bodies } }
        var requestURLs: [URL] { lock.withLock { urls } }
        /// The requests answered with a chat reply (everything the `responder` didn't answer), in order.
        var chats: [String] { lock.withLock { chatBodies } }

        func record(_ request: URLRequest, body: String) {
            lock.withLock {
                bodies.append(body)
                urls.append(request.url!)
            }
        }

        /// Counts a chat request and returns its number, starting at 1.
        func recordChat(_ body: String) -> Int {
            lock.withLock {
                chatBodies.append(body)
                return chatBodies.count
            }
        }
    }

    private struct Server {
        let log: Log
        let responder: Responder?
        var chatResponder: ChatResponder? = nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: Server] = [:]
    /// Registered once for the whole test run; `canInit` only claims hosts that have been started.
    private static let registration: Void = { URLProtocol.registerClass(MockModelServer.self) }()

    @discardableResult
    static func start(host: String = host, responder: Responder? = nil) -> Log {
        _ = registration
        let log = Log()
        lock.withLock { servers[host] = Server(log: log, responder: responder) }
        return log
    }

    /// Like `start`, but chat replies are chosen by `chat` from each request's body (for tests that need
    /// different replies to different kinds of request).
    @discardableResult
    static func start(host: String = host, responder: Responder? = nil, chat: @escaping ChatResponder) -> Log {
        _ = registration
        let log = Log()
        lock.withLock { servers[host] = Server(log: log, responder: responder, chatResponder: chat) }
        return log
    }

    static func stop(host: String = host) {
        _ = lock.withLock { servers.removeValue(forKey: host) }
    }

    private static func server(for request: URLRequest) -> Server? {
        guard let host = request.url?.host() else { return nil }
        return lock.withLock { servers[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { server(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body = Self.body(of: request)
        server.log.record(request, body: body)
        let status: Int, contentType: String, payload: String
        if let answer = server.responder?(request) {
            (status, contentType, payload) = (answer.status, "application/json", answer.body)
        } else if let text = server.chatResponder?(body) {
            _ = server.log.recordChat(body)
            let content = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
            let chunk = #"{"choices":[{"delta":{"content":\#(content)}}]}"#
            (status, contentType, payload) = (200, "text/event-stream", "data: \(chunk)\n\ndata: [DONE]\n\n")
        } else {
            let number = server.log.recordChat(body)
            let chunk = #"{"choices":[{"delta":{"content":"Reply \#(number)"}}]}"#
            (status, contentType, payload) = (200, "text/event-stream", "data: \(chunk)\n\ndata: [DONE]\n\n")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["content-type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream, not `httpBody`.
    private static func body(of request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
