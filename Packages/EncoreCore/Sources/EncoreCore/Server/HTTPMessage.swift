import Foundation

// The HTTP/1.1 pieces the local API needs: a request read whole, a response that is either bytes or a stream of
// chunks, an incremental request parser and a multipart/form-data reader. Nothing here touches the network.

/// One request, read whole.
public struct HTTPRequest: Sendable {
    public var method: String
    /// Percent-decoded, without the query.
    public var path: String
    public var query: [String: String]
    /// Header names lowercased; repeated headers joined with ", ".
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:],
                body: Data = Data()) {
        self.method = method; self.path = path; self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { a, b in "\(a), \(b)" }
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The body's media type, lowercased, without parameters ("multipart/form-data").
    public var contentType: String? {
        header("content-type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// True when the client said it takes this media type (or anything).
    public func accepts(_ type: String) -> Bool {
        guard let accept = header("accept")?.lowercased() else { return false }
        return accept.split(separator: ",").contains {
            let t = $0.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return t == type || t == "*/*"
        }
    }
}

/// A response: bytes with a known length, or a stream sent with chunked transfer encoding.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Body

    public enum Body: Sendable {
        case data(Data)
        /// Each element is sent as one chunk as soon as it arrives. Ending the stream ends the response.
        case stream(AsyncStream<Data>)
    }

    public init(status: Int = 200, headers: [String: String] = [:], body: Body = .data(Data())) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func data(_ data: Data, type: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers.merging(["Content-Type": type]) { $1 }, body: .data(data))
    }

    public static func text(_ text: String, type: String = "text/plain; charset=utf-8", status: Int = 200) -> HTTPResponse {
        .data(Data(text.utf8), type: type, status: status)
    }

    /// A JSON object or array (anything `JSONSerialization` takes).
    public static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return .data(data, type: "application/json", status: status, headers: headers)
    }

    public static func empty(_ status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }

    /// The status line and headers, ending with the blank line.
    func head(chunked: Bool, contentLength: Int?) -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
        var fields = headers
        fields["Connection"] = "close"
        fields["Cache-Control"] = fields["Cache-Control"] ?? "no-store"
        if chunked { fields["Transfer-Encoding"] = "chunked" } else if let contentLength { fields["Content-Length"] = String(contentLength) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            // Header values must be one line of visible ASCII.
            let clean = String(value.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F ? Character($0) : "?" })
            lines.append("\(name): \(clean)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}

/// Reads one request from bytes as they arrive. Bodies are framed by Content-Length or chunked transfer encoding.
struct HTTPRequestParser {
    var maxHeaderBytes = 64 * 1024
    /// Uploads larger than this are refused (413); the native endpoints take file paths instead.
    var maxBodyBytes = 1024 * 1024 * 1024

    enum Outcome {
        case needMore
        case complete(HTTPRequest)
        case failed(status: Int, message: String)
    }

    /// True once the head is read and the client sent `Expect: 100-continue` (curl does for large uploads).
    private(set) var expectsContinue = false

    private var buffer = Data()
    private var head: Head?

    private struct Head {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var framing: Framing
    }

    private enum Framing { case length(Int), chunked }

    private static let headEnd = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)

    mutating func feed(_ data: Data) -> Outcome {
        buffer.append(data)
        if head == nil {
            guard let end = buffer.range(of: Self.headEnd) else {
                return buffer.count > maxHeaderBytes ? .failed(status: 431, message: "The request's headers are too large.") : .needMore
            }
            guard end.lowerBound - buffer.startIndex <= maxHeaderBytes else {
                return .failed(status: 431, message: "The request's headers are too large.")
            }
            let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer = Data(buffer[end.upperBound...])
            switch Self.parseHead(text, maxBody: maxBodyBytes) {
            case .success(let h):
                head = h
                expectsContinue = h.headers["expect"]?.lowercased() == "100-continue"
            case .failure(let f):
                return .failed(status: f.status, message: f.message)
            }
        }
        guard let head else { return .needMore }
        switch head.framing {
        case .length(let n):
            guard buffer.count >= n else { return .needMore }
            return .complete(request(head, body: Data(buffer.prefix(n))))
        case .chunked:
            switch Self.decodeChunked(buffer, max: maxBodyBytes) {
            case .needMore: return .needMore
            case .done(let body): return .complete(request(head, body: body))
            case .invalid(let status, let message): return .failed(status: status, message: message)
            }
        }
    }

    private func request(_ h: Head, body: Data) -> HTTPRequest {
        HTTPRequest(method: h.method, path: h.path, query: h.query, headers: h.headers, body: body)
    }

    private struct HeadFailure: Error { var status: Int; var message: String }

    private static func parseHead(_ text: String, maxBody: Int) -> Result<Head, HeadFailure> {
        let bad = { (m: String) in Result<Head, HeadFailure>.failure(HeadFailure(status: 400, message: m)) }
        var lines = text.components(separatedBy: "\r\n")
        // Tolerate blank lines before the request line (RFC 9112 §2.2).
        while lines.first?.isEmpty == true { lines.removeFirst() }
        guard !lines.isEmpty else { return bad("The request is empty.") }
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty,
              parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }) else { return bad("The request line isn't HTTP/1.1.") }
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return bad("The request target must be a path.") }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line[..<colon].contains(where: { $0 == " " || $0 == "\t" }) else { return bad("A header line is malformed.") }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        let framing: Framing
        if let te = headers["transfer-encoding"]?.lowercased() {
            guard te.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) }) == "chunked" else {
                return .failure(HeadFailure(status: 501, message: "Only chunked transfer encoding is supported."))
            }
            framing = .chunked
        } else if let cl = headers["content-length"] {
            // Repeated identical values ("12, 12") are allowed; anything else is not.
            let values = Set(cl.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            guard values.count == 1, let v = values.first, let n = Int(v), n >= 0 else { return bad("Content-Length is invalid.") }
            guard n <= maxBody else { return .failure(HeadFailure(status: 413, message: "The request body is too large.")) }
            framing = .length(n)
        } else {
            framing = .length(0)
        }

        var components = URLComponents()
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.percentEncodedPath = String(split[0])
        if split.count > 1 { components.percentEncodedQuery = String(split[1]) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        return .success(Head(method: String(parts[0]), path: components.path, query: query, headers: headers, framing: framing))
    }

    enum ChunkedResult: Equatable { case needMore, done(Data), invalid(Int, String) }

    /// Decodes a complete chunked body from the start of `data`, or says more is needed.
    static func decodeChunked(_ data: Data, max: Int) -> ChunkedResult {
        var body = Data()
        var pos = data.startIndex
        while true {
            guard let lineEnd = data.range(of: crlf, in: pos..<data.endIndex) else {
                return data.endIndex - pos > 1024 ? .invalid(400, "A chunk size line is malformed.") : .needMore
            }
            let sizeText = String(decoding: data[pos..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, sizeText.count <= 15, let size = Int(sizeText, radix: 16), size >= 0 else {
                return .invalid(400, "A chunk size is malformed.")
            }
            pos = lineEnd.upperBound
            if size == 0 {
                // Optional trailers, then the blank line.
                if data.endIndex - pos >= 2, data[pos..<pos + 2] == crlf { return .done(body) }
                return data.range(of: headEnd, in: pos..<data.endIndex) != nil ? .done(body) : .needMore
            }
            guard body.count + size <= max else { return .invalid(413, "The request body is too large.") }
            guard data.endIndex - pos >= size + 2 else { return .needMore }
            body.append(data[pos..<pos + size])
            pos += size
            guard data[pos..<pos + 2] == crlf else { return .invalid(400, "A chunk isn't followed by CRLF.") }
            pos += 2
        }
    }
}

/// A multipart/form-data body (RFC 7578).
struct MultipartForm {
    struct Part {
        var name: String
        var filename: String?
        var contentType: String?
        var data: Data
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    var parts: [Part]

    /// The first plain field with this name.
    func value(_ name: String) -> String? { parts.first { $0.name == name && $0.filename == nil }?.text }
    func values(_ name: String) -> [String] { parts.filter { $0.name == name && $0.filename == nil }.map(\.text) }
    func file(_ name: String) -> Part? { parts.first { $0.name == name && $0.filename != nil } ?? parts.first { $0.name == name } }

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func parse(_ body: Data, contentType header: String) throws -> MultipartForm {
        guard let boundary = parameters(header)["boundary"], !boundary.isEmpty else {
            throw Failure(message: "The multipart body has no boundary.")
        }
        let delimiter = Data("--\(boundary)".utf8)
        let separator = Data("\r\n--\(boundary)".utf8)
        guard var pos = body.range(of: delimiter)?.upperBound else { throw Failure(message: "The multipart body has no parts.") }
        var parts: [Part] = []
        while true {
            // "--" after a delimiter ends the body.
            if body.endIndex - pos >= 2, body[pos..<pos + 2] == Data("--".utf8) { break }
            guard let lineEnd = body.range(of: Data("\r\n".utf8), in: pos..<body.endIndex) else {
                throw Failure(message: "The multipart body ends early.")
            }
            pos = lineEnd.upperBound
            guard let headEnd = body.range(of: Data("\r\n\r\n".utf8), in: pos..<body.endIndex) else {
                throw Failure(message: "A multipart part has no headers.")
            }
            var headers: [String: String] = [:]
            for line in String(decoding: body[pos..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let next = body.range(of: separator, in: headEnd.upperBound..<body.endIndex) else {
                throw Failure(message: "A multipart part isn't closed.")
            }
            let disposition = parameters(headers["content-disposition"] ?? "")
            if let name = disposition["name"] {
                parts.append(Part(name: name, filename: disposition["filename"], contentType: headers["content-type"],
                                  data: Data(body[headEnd.upperBound..<next.lowerBound])))
            }
            pos = next.upperBound
        }
        return MultipartForm(parts: parts)
    }

    /// `type; key=value; key="quoted; value"` → [key: value], keys lowercased.
    static func parameters(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for ch in header {
            if escaped { current.append(ch); escaped = false; continue }
            if quoted && ch == "\\" { escaped = true; continue }
            if ch == "\"" { quoted.toggle(); continue }
            if ch == ";" && !quoted { pieces.append(current); current = ""; continue }
            current.append(ch)
        }
        pieces.append(current)
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            result[key] = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
