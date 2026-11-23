import Foundation
import Network

public typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

/// A small HTTP/1.1 server bound to 127.0.0.1, so nothing outside this Mac can reach it. One request per connection
/// (`Connection: close`); streamed responses use chunked encoding. If the client goes away while a request is being
/// handled, the handler's task is canceled, which stops any generation it started.
public final class LocalHTTPServer: @unchecked Sendable {
    public enum StartError: LocalizedError, Equatable {
        case portInUse(Int)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .portInUse(let port): "Port \(port) is already in use by another app. Pick another port."
            case .failed(let message): "The local API couldn't start: \(message)"
            }
        }
    }

    /// The port asked for; 0 picks a free one (see `boundPort`).
    public let requestedPort: Int
    private let handler: HTTPHandler
    private let queue = DispatchQueue(label: "dev.abdeen.encore.local-api")
    // Everything below is touched only on `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var actualPort: Int?

    public init(port: Int, handler: @escaping HTTPHandler) {
        requestedPort = port
        self.handler = handler
    }

    /// The port the server is listening on, once started.
    public var boundPort: Int? { queue.sync { actualPort } }

    /// Starts listening and returns once the port is open, or throws `StartError`.
    public func start() async throws {
        guard (0...65535).contains(requestedPort), let port = NWEndpoint.Port(rawValue: UInt16(requestedPort)) else {
            throw StartError.failed("\(requestedPort) isn't a valid port.")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw Self.startError(error, port: requestedPort) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                var resumed = false
                let finish = { (result: Result<Void, Error>) in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(with: result)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.actualPort = listener.port.map { Int($0.rawValue) }
                        finish(.success(()))
                    case .failed(let error):
                        listener.cancel()
                        finish(.failure(Self.startError(error, port: self?.requestedPort ?? 0)))
                    case .waiting(let error):
                        // The address can't be used right now (usually: in use). Don't wait for it.
                        listener.cancel()
                        finish(.failure(Self.startError(error, port: self?.requestedPort ?? 0)))
                    case .cancelled:
                        finish(.failure(StartError.failed("It was stopped.")))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                listener.start(queue: self.queue)
            }
        }
    }

    /// Stops listening and drops every open connection (canceling their requests).
    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.actualPort = nil
            for c in self.connections.values { c.close() }
            self.connections = [:]
        }
    }

    private func accept(_ connection: NWConnection) {
        let c = HTTPConnection(connection: connection, queue: queue, handler: handler)
        let id = ObjectIdentifier(c)
        connections[id] = c
        c.onClose = { [weak self] in self?.connections[id] = nil }
        c.start()
    }

    private static func startError(_ error: Error, port: Int) -> StartError {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE { return .portInUse(port) }
        return .failed(error.localizedDescription)
    }
}

/// One client connection: reads a request, runs the handler, writes the response, closes.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPHandler
    // Touched only on `queue`.
    private var parser = HTTPRequestParser()
    private var sentContinue = false
    private var task: Task<Void, Never>?
    private var closed = false
    var onClose: (() -> Void)?

    /// A request must arrive whole within this long.
    static let requestTimeout: TimeInterval = 60

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPHandler) {
        self.connection = connection; self.queue = queue; self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard let self, self.task == nil, !self.closed else { return }
            self.respondAndClose(.text("The request didn't arrive in time.", status: 408))
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty, self.task == nil {
                switch self.parser.feed(data) {
                case .needMore:
                    if self.parser.expectsContinue, !self.sentContinue {
                        self.sentContinue = true
                        self.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                    }
                case .complete(let request):
                    self.dispatch(request)
                case .failed(let status, let message):
                    self.respondAndClose(.json(["error": ["message": message, "type": "invalid_request_error", "code": "bad_request"]],
                                               status: status))
                    return
                }
            }
            if isComplete || error != nil {
                // The client closed its side: stop whatever it asked for.
                self.close()
                return
            }
            // Keep reading while the handler runs, so a disconnect is noticed.
            self.receive()
        }
    }

    private func dispatch(_ request: HTTPRequest) {
        let handler = self.handler
        task = Task { [weak self] in
            let response = await handler(request)
            await self?.write(response)
            self?.queue.async { self?.close() }
        }
    }

    private func respondAndClose(_ response: HTTPResponse) {
        task = Task { [weak self] in
            await self?.write(response)
            self?.queue.async { self?.close() }
        }
    }

    private func write(_ response: HTTPResponse) async {
        switch response.body {
        case .data(let body):
            var bytes = response.head(chunked: false, contentLength: body.count)
            bytes.append(body)
            _ = await send(bytes, final: true)
        case .stream(let chunks):
            guard await send(response.head(chunked: true, contentLength: nil), final: false) else { return }
            for await chunk in chunks where !chunk.isEmpty {
                var framed = Data((String(chunk.count, radix: 16) + "\r\n").utf8)
                framed.append(chunk)
                framed.append(Data("\r\n".utf8))
                guard await send(framed, final: false) else { return }
            }
            _ = await send(Data("0\r\n\r\n".utf8), final: true)
        }
    }

    /// False when the connection is gone. Each send is a complete message (TCP keeps no boundaries, so nothing closes);
    /// `final` also ends our side of the connection once the bytes are out.
    private func send(_ data: Data, final: Bool) async -> Bool {
        if Task.isCancelled { return false }
        return await withCheckedContinuation { continuation in
            connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                            completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }

    /// Cancels the request (if any) and the connection. Call on `queue`.
    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        connection.cancel()
        onClose?()
        onClose = nil
    }
}
