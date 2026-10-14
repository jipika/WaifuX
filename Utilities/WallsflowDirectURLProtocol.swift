import Foundation

/// Kingfisher's per-host bridge into the same transport used by Wallsflow videos.
/// That transport preserves the browser identity and can download through WebKit.
final class WallsflowDirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handledHeader = "X-WaifuX-Wallsflow-Direct"
    // stopLoading and asynchronous completions can arrive on different threads.
    // Recursive locking also permits a client callback to synchronously stop this load.
    private let stateLock = NSRecursiveLock()
    private var loadTask: Task<Void, Never>?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard request.value(forHTTPHeaderField: handledHeader) == nil,
              let url = request.url else { return false }
        return WallsflowMediaPolicy.owns(url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        stateLock.withLock {
            guard !stopped, loadTask == nil else { return }
            var outbound = request
            outbound.setValue(nil, forHTTPHeaderField: Self.handledHeader)
            loadTask = Task { @Sendable [weak self, outbound] in
                do {
                    guard let url = outbound.url else { throw URLError(.badURL) }
                    let data = try await WallsflowService.shared.fetchMediaData(
                        from: url, headers: outbound.allHTTPHeaderFields ?? [:]
                    )
                    try Task.checkCancellation()
                    self?.complete(.success(data))
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

    private func complete(_ result: Result<Data, Error>) {
        stateLock.withLock {
            guard !stopped else { return }
            loadTask = nil
            switch result {
            case .success(let data):
                guard let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                     headerFields: ["Content-Length": String(data.count)]) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    stopped = true
                    return
                }
                // Only validated media reaches this point. Kingfisher owns its image cache.
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
