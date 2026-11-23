import Foundation

/// Kingfisher hooks only eligible image reads. Declined requests use the normal proxy-aware URLSession.
final class DirectConnectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let fallbackSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [] // not this protocol; never emit an internal marker header
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private let stateLock = NSRecursiveLock()
    private var loadTask: Task<Void, Never>?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        DirectConnectPolicy.strategy(for: request, imagesOnly: true) != .none && DirectConnectPolicy.shared.isActive()
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest else { return false }
        return canInit(with: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        stateLock.withLock {
            guard !stopped, loadTask == nil else { return }
            let outbound = request
            loadTask = Task { @Sendable [weak self, outbound] in
                do {
                    let data: Data
                    let response: URLResponse
                    if let direct = try await DirectConnectRouter.shared.attempt(request: outbound), let url = outbound.url {
                        var headers = direct.headers.filter { !["connection", "transfer-encoding"].contains($0.key) }
                        headers["content-length"] = String(direct.body.count)
                        guard let http = HTTPURLResponse(url: url, statusCode: direct.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                            throw URLError(.badServerResponse)
                        }
                        response = http
                        data = direct.body
                    } else {
                        (data, response) = try await Self.fallbackSession.data(for: outbound)
                    }
                    try Task.checkCancellation()
                    self?.complete(.success((data, response)))
                } catch let terminal as DirectConnectRouter.Terminal {
                    self?.complete(.failure(terminal.underlying))
                } catch {
                    self?.complete(.failure(error))
                }
            }
        }
    }

    override func stopLoading() {
        stateLock.withLock {
            stopped = true
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private func complete(_ result: Result<(Data, URLResponse), Error>) {
        stateLock.withLock {
            guard !stopped else { return }
            loadTask = nil
            switch result {
            case .success(let (data, response)):
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                guard !stopped else { return }
                client?.urlProtocol(self, didLoad: data)
                guard !stopped else { return }
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
            stopped = true
        }
    }
}
