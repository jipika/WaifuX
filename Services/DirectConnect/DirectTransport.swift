import Foundation
import Network
import Security

/// Bounded HTTP/1.1 GET over a verified TLS connection to a resolved address.
enum DirectTransport {
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        let cookies: [String]
    }

    enum TransportError: Error {
        case badResponse
        case unsupportedResponse
        case tooLarge
    }

    static let maxHeaderBytes = 32 * 1024
    static let maxWireBytes = 24 * 1024 * 1024
    private static let separator = Data("\r\n\r\n".utf8)
    private static let crlf = Data("\r\n".utf8)
    private static let token = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~".utf8)

    static func get(url: URL, ip: String, sni: Bool, headers: [String: String], timeout: TimeInterval) async throws -> Response {
        guard let host = url.host, let address = IPv4Address(ip) else { throw TransportError.badResponse }
        let request = try requestBytes(url: url, headers: headers)
        let runner = RequestRunner(host: host, address: address, sni: sni, request: request, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await runner.run()
        } onCancel: {
            runner.cancel()
        }
    }

    static func requestBytes(url: URL, headers: [String: String]) throws -> Data {
        guard let host = url.host, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw TransportError.badResponse
        }
        var target = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { target += "?" + query }
        guard target.first == "/", target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw TransportError.badResponse }
        var fields = ["accept": "*/*", "user-agent": "WaifuX", "host": host, "connection": "close", "accept-encoding": "identity"]
        let excluded = Set(["host", "connection", "accept-encoding", "transfer-encoding", "content-length", "proxy-authorization", "proxy-connection", "upgrade", "te", "trailer", "keep-alive"])
        for (name, value) in headers {
            let key = name.lowercased()
            guard !excluded.contains(key) else { continue }
            guard !key.isEmpty, key.utf8.allSatisfy(token.contains),
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { throw TransportError.badResponse }
            fields[key] = value
        }
        let data = Data(("GET \(target) HTTP/1.1\r\n" + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
        guard data.count <= maxHeaderBytes else { throw TransportError.tooLarge }
        return data
    }

    static func sanMatches(trust: SecTrust, host: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert = chain.first,
              let fields = SecCertificateCopyValues(cert, [kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any],
              let san = fields[kSecOIDSubjectAltName as String] as? [String: Any],
              let entries = san[kSecPropertyKeyValue as String] as? [[String: Any]] else { return false }
        let host = host.lowercased()
        return entries.contains { entry in
            guard let name = (entry[kSecPropertyKeyValue as String] as? String)?.lowercased() else { return false }
            if name == host { return true }
            return name.hasPrefix("*.") && host.hasSuffix(String(name.dropFirst())) &&
                host.split(separator: ".").count == name.split(separator: ".").count
        }
    }

    /// An incomplete content-length or chunked response is always an error at EOF.
    static func response(in wire: Data, atEOF: Bool) throws -> Response? {
        guard wire.count <= maxWireBytes else { throw TransportError.tooLarge }
        guard let split = wire.prefix(maxHeaderBytes).range(of: separator) else {
            if wire.count >= maxHeaderBytes || atEOF { throw TransportError.badResponse }
            return nil
        }
        let lines = String(decoding: wire[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let statusLine = lines.first?.split(separator: " ") ?? []
        guard statusLine.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(statusLine[0]),
              let status = Int(statusLine[1]), (200...599).contains(status) else { throw TransportError.badResponse }
        var fields: [String: String] = [:]
        var cookies: [String] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw TransportError.badResponse }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy(token.contains) else { throw TransportError.badResponse }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "set-cookie" { cookies.append(value); continue }
            if ["content-length", "transfer-encoding", "content-encoding"].contains(name), fields[name] != nil {
                throw TransportError.badResponse
            }
            fields[name] = value
        }
        if let encoding = fields["content-encoding"], encoding.lowercased() != "identity" {
            throw TransportError.unsupportedResponse
        }
        let body = wire[split.upperBound...]
        let output: Data
        if [204, 205, 304].contains(status) {
            output = Data()
        } else if let transfer = fields["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", fields["content-length"] == nil else { throw TransportError.badResponse }
            // We send Connection: close. Decode once at EOF, not on every receive.
            guard atEOF else { return nil }
            output = try decodeChunks(body)
        } else if let length = fields["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length) else {
                throw TransportError.badResponse
            }
            guard count <= maxWireBytes - split.upperBound + wire.startIndex else { throw TransportError.tooLarge }
            guard body.count == count else {
                if !atEOF && body.count < count { return nil }
                throw TransportError.badResponse
            }
            output = Data(body)
        } else {
            guard atEOF else { return nil }
            output = Data(body)
        }
        return Response(status: status, headers: fields, body: output, cookies: cookies)
    }

    private static func decodeChunks(_ data: Data) throws -> Data {
        var result = Data()
        var cursor = data.startIndex
        while let eol = data[cursor...].prefix(1024).range(of: crlf) {
            let size = String(decoding: data[cursor..<eol.lowerBound], as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)[0]
            guard !size.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let length = Int(size, radix: 16) else { throw TransportError.badResponse }
            cursor = eol.upperBound
            if length == 0 {
                let trailers = data[cursor...]
                if trailers == crlf || (trailers.count <= maxHeaderBytes && trailers.suffix(4) == separator) { return result }
                throw TransportError.badResponse
            }
            guard data.endIndex - cursor >= 2, length <= data.endIndex - cursor - 2 else { throw TransportError.badResponse }
            let end = cursor + length
            guard data[end..<end + 2] == crlf else { throw TransportError.badResponse }
            result.append(data[cursor..<end])
            cursor = end + 2
        }
        throw TransportError.badResponse
    }
}

/// The connection, timer and continuation are owned exclusively by a serial queue.
private final class RequestRunner: @unchecked Sendable {
    private let host: String
    private let address: IPv4Address
    private let sni: Bool
    private let request: Data
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.waifux.direct-transport", qos: .userInitiated)
    private var continuation: CheckedContinuation<DirectTransport.Response, Error>?
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var wire = Data()
    private var finished = false

    init(host: String, address: IPv4Address, sni: Bool, request: Data, timeout: TimeInterval) {
        self.host = host
        self.address = address
        self.sni = sni
        self.request = request
        self.timeout = timeout
    }

    func run() async throws -> DirectTransport.Response {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.finished else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.start()
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func start() {
        let tls = NWProtocolTLS.Options()
        let domain = host
        if sni { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, domain) }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, domain as CFString)
            guard SecTrustSetPolicies(reference, policy) == errSecSuccess else { complete(false); return }
            complete(SecTrustEvaluateWithError(reference, nil) && DirectTransport.sanMatches(trust: reference, host: domain))
        }, DispatchQueue.global(qos: .userInitiated))
        let connection = NWConnection(host: .ipv4(address), port: .https, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                self.connection?.send(content: self.request, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.finished else { return }
                    if let error { self.finish(.failure(error)) } else { self.receive() }
                })
            case .failed(let error): self.finish(.failure(error))
            case .cancelled: self.finish(.failure(CancellationError()))
            default: break
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
        timer.schedule(deadline: .now() + timeout)
        self.timer = timer
        timer.resume()
        connection.start(queue: queue)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, eof, error in
            guard let self, !self.finished else { return }
            if let error { self.finish(.failure(error)); return }
            if let data {
                guard data.count <= DirectTransport.maxWireBytes - self.wire.count else {
                    self.finish(.failure(DirectTransport.TransportError.tooLarge)); return
                }
                self.wire.append(data)
            }
            do {
                if let response = try DirectTransport.response(in: self.wire, atEOF: eof) {
                    self.finish(.success(response))
                } else {
                    self.receive()
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<DirectTransport.Response, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        wire = Data()
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
