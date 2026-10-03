import Foundation
import Network

/// Minimal HTTP/1.1 server that accepts OTLP/HTTP JSON exports.
/// `/v1/metrics` carries Claude Code usage and `/v1/traces` GitHub Copilot CLI usage; each is
/// parsed only while its provider is accepted. Other paths (e.g. `/v1/logs`) are acknowledged and dropped.
final class OTLPServer: @unchecked Sendable {
    enum State: Equatable { case stopped, listening(port: UInt16), failed(String) }

    private let queue = DispatchQueue(label: "LLMUsageBar.OTLPServer")
    private var listener: NWListener?
    private let onPoints: @Sendable ([UsagePoint]) -> Void
    private let onSpans: @Sendable ([CopilotSpan]) -> Void
    private let onState: @Sendable (State) -> Void
    /// Which payloads to parse; set together with start(port:accept:).
    private var acceptMetrics = false
    private var acceptTraces = false


    init(onPoints: @escaping @Sendable ([UsagePoint]) -> Void,
         onSpans: @escaping @Sendable ([CopilotSpan]) -> Void,
         onState: @escaping @Sendable (State) -> Void) {
        self.onPoints = onPoints
        self.onSpans = onSpans
        self.onState = onState
    }

    /// Listens on 127.0.0.1 only. Changing only which payloads are accepted keeps the
    /// current listener; a new listener is created only when the port changes or none is running.
    func start(port: UInt16, metrics: Bool, traces: Bool) {
        queue.async { [self] in
            acceptMetrics = metrics
            acceptTraces = traces
            wantedPort = port
            if listener != nil && listenerPort == port { return }
            openListener()
        }
    }

    func stop() {
        queue.async { [self] in
            acceptMetrics = false
            acceptTraces = false
            wantedPort = nil
            closeListener()
            connections.values.forEach { $0.cancel() }
            connections = [:]
            onState(.stopped)
        }
    }

    // MARK: Listener (all on `queue`)

    private var wantedPort: UInt16?
    private var listenerPort: UInt16?
    private var retryWork: DispatchWorkItem?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private func closeListener() {
        retryWork?.cancel()
        retryWork = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        listenerPort = nil
    }

    private func openListener() {
        closeListener()
        guard let port = wantedPort else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onState(.failed("Invalid port \(port)"))
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self, weak l] state in
                // Ignore late callbacks from a listener that has been replaced.
                guard let self, let l, self.listener === l else { return }
                switch state {
                case .ready:
                    self.onState(.listening(port: port))
                case .failed(let e):
                    // e.g. the port is still held briefly by a previous socket: retry.
                    self.onState(.failed(e.localizedDescription))
                    self.scheduleRetry()
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener = l
            listenerPort = port
            l.start(queue: queue)
        } catch {
            onState(.failed(error.localizedDescription))
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        listenerPort = nil
        let work = DispatchWorkItem { [weak self] in self?.openListener() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.connections[id] = nil
            default: break
            }
        }
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let chunk { buf.append(chunk) }
            if error != nil || buf.count > HTTPRequest.maxBodySize + 64 * 1024 {
                conn.cancel()
                return
            }
            switch HTTPRequest.parse(buf) {
            case .complete(let req, let consumed):
                self.handle(req, on: conn)
                let rest = Data(buf.dropFirst(consumed))
                if isComplete { conn.cancel() } else { self.receive(conn, buffer: rest) }
            case .incomplete:
                if isComplete { conn.cancel() } else { self.receive(conn, buffer: buf) }
            case .invalid:
                self.respond(conn, status: "400 Bad Request", close: true)
            }
        }
    }

    private func handle(_ req: HTTPRequest, on conn: NWConnection) {
        guard req.method == "POST" else {
            respond(conn, status: req.method == "GET" ? "200 OK" : "405 Method Not Allowed", close: false)
            return
        }
        if req.headers["content-encoding"].map({ $0 != "identity" }) ?? false {
            respond(conn, status: "415 Unsupported Media Type", close: false)
            return
        }
        let isMetrics = req.path.hasPrefix("/v1/metrics"), isTraces = req.path.hasPrefix("/v1/traces")
        if (isMetrics || isTraces) && req.headers["content-type"]?.contains("protobuf") == true {
            respond(conn, status: "415 Unsupported Media Type", close: false)
            return
        }
        if isMetrics && acceptMetrics {
            let points = OTLPParser.parseMetrics(req.body)
            if !points.isEmpty { onPoints(points) }
        }
        if isTraces && acceptTraces {
            let spans = CopilotParser.parseTraces(req.body)
            if !spans.isEmpty { onSpans(spans) }
        }
        respond(conn, status: "200 OK", close: false)
    }

    private func respond(_ conn: NWConnection, status: String, close: Bool) {
        let body = "{}"
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
            + (close ? "Connection: close\r\n" : "") + "\r\n"
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            if close { conn.cancel() }
        })
    }
}

struct HTTPRequest {
    enum ParseResult { case complete(HTTPRequest, consumed: Int), incomplete, invalid }
    private enum ChunkedResult { case complete(Data, end: Data.Index), incomplete, invalid }

    /// Largest accepted request body.
    static let maxBodySize = 16 * 1024 * 1024

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ buf: Data) -> ParseResult {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: buf[buf.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        let bodyStart = headerEnd.upperBound
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        if headers["transfer-encoding"]?.contains("chunked") == true {
            switch decodeChunked(buf, from: bodyStart) {
            case .complete(let body, let end):
                return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body),
                                 consumed: end - buf.startIndex)
            case .incomplete: return .incomplete
            case .invalid: return .invalid
            }
        }
        // A missing Content-Length means no body; a malformed, negative, or oversized one is invalid.
        var length = 0
        if let value = headers["content-length"] {
            guard let n = Int(value), n >= 0, n <= maxBodySize else { return .invalid }
            length = n
        }
        guard buf.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(buf[bodyStart..<(bodyStart + length)])
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body),
                         consumed: bodyStart + length - buf.startIndex)
    }

    /// Decodes a chunked body. A chunk size must be hexadecimal digits only (optionally followed by
    /// extensions after ";"), and the decoded body must not exceed `maxBodySize`.
    private static func decodeChunked(_ buf: Data, from start: Data.Index) -> ChunkedResult {
        var body = Data()
        var i = start
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = buf.range(of: crlf, in: i..<buf.endIndex) else { return .incomplete }
            guard let sizeLine = String(data: buf[i..<lineEnd.lowerBound], encoding: .utf8) else { return .invalid }
            let digits = sizeLine.split(separator: ";", omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit),
                  let size = Int(digits, radix: 16), size <= maxBodySize - body.count
            else { return .invalid }
            let dataStart = lineEnd.upperBound
            if size == 0 {
                // Skip optional trailers up to the final CRLF.
                guard let end = buf.range(of: Data("\r\n\r\n".utf8), in: lineEnd.lowerBound..<buf.endIndex)
                else { return .incomplete }
                return .complete(body, end: end.upperBound)
            }
            guard buf.endIndex - dataStart >= size + 2 else { return .incomplete }
            body.append(buf[dataStart..<(dataStart + size)])
            i = dataStart + size + 2
        }
    }
}
