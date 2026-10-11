import Foundation

/// 把「动态桌面」封面走 Kingfisher 的请求，转成本地抽帧结果。
///
/// 服务端截图接口（`?x-oss-process=video/snapshot,...`）随数据源迁移失效后，
/// 封面改由 `DynamicWallpaperPosterService` 在客户端生成（Range 取片 + AVFoundation 抽帧）。
/// 探索页封面统一经 Kingfisher 的「URL → 图片」管线加载，
/// 因此在传输层挂一个必然不出网的伪 host：
/// - Kingfisher 的内存/磁盘缓存、候选回退、取消与复用逻辑全部保留；
/// - 抽帧结果按 URL 缓存，同一视频只生成一次；
/// - 失败时走正常的下载失败路径（卡片保留占位底色，不再回退到会下载整段视频的地址）。
///
/// 伪 host 用 `.invalid` 保留顶级域：万一某条链路没注册本 Protocol，DNS 会立刻失败，
/// 不会意外发出真实请求（`.local` 会走 mDNS 查询，慢且噪声大）。
final class DynamicWallpaperPosterURLProtocol: URLProtocol, @unchecked Sendable {

    /// 注意：URLProtocol 基类已有 `task`（URLSessionTask?）属性，这里必须换个名字。
    private var activeTask: Task<Void, Never>?

    /// 跨并发域携带的请求上下文：`URLProtocolClient` 本身不是 Sendable，
    /// 用 @unchecked Sendable 包装（其回调本就可从任意线程调用）。
    private struct LoadContext: @unchecked Sendable {
        let client: URLProtocolClient?
        let url: URL
    }

    override class func canInit(with request: URLRequest) -> Bool {
        isPosterRequest(request.url)
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        isPosterRequest(task.currentRequest?.url)
    }

    private class func isPosterRequest(_ url: URL?) -> Bool {
        url?.host?.lowercased() == DynamicWallpaperPosterRoute.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let videoURL = DynamicWallpaperPosterRoute.videoURL(from: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // 抽帧要跨并发域执行：URLProtocolClient 不是 Sendable，先包成上下文再进 Task，
        // 闭包只捕获 Sendable 值（Swift 6 严格并发下不触碰 self 的隔离状态）。
        let context = LoadContext(client: client, url: url)

        activeTask = Task { [context] in
            do {
                let data = try await DynamicWallpaperPosterService.shared.posterJPEG(for: videoURL)
                guard !Task.isCancelled else { return }
                let response = HTTPURLResponse(
                    url: context.url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "image/jpeg",
                        "Content-Length": String(data.count)
                    ]
                ) ?? URLResponse(
                    url: context.url,
                    mimeType: "image/jpeg",
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                context.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
                context.client?.urlProtocol(self, didLoad: data)
                context.client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                context.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        activeTask?.cancel()
        activeTask = nil
    }
}
