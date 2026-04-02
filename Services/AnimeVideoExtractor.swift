import Foundation
import WebKit
import Combine

// MARK: - 视频提取结果

enum VideoExtractionResult {
    case success([VideoSource])
    case error(String)
    case captcha
    case timeout
}

// MARK: - 视频提取器

/// 使用 WKWebView 提取视频 URL（参考 Kazumi 实现）
/// 通过 JavaScript 注入拦截 M3U8 和视频请求
@MainActor
class AnimeVideoExtractor: NSObject {
    static let shared = AnimeVideoExtractor()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<VideoExtractionResult, Never>?
    private var timer: Timer?
    private var foundSources: Set<String> = []
    private var isLoading = false

    // 配置
    private let timeout: TimeInterval = 30.0
    private let pollInterval: TimeInterval = 1.0

    // 用户代理列表（随机选择）
    private let userAgents = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ]

    private override init() {
        super.init()
    }

    // MARK: - 提取视频

    /// 从剧集页面提取视频 URL
    func extractVideoSources(from episodeURL: String, rule: AnimeRule) async -> VideoExtractionResult {
        print("[VideoExtractor] 开始提取视频: \(episodeURL)")

        // 如果规则有直接视频选择器，先尝试直接解析
        if rule.videoSelector != nil {
            do {
                let sources = try await AnimeParser.shared.fetchVideoSources(
                    episodeURL: episodeURL,
                    rule: rule
                )
                if !sources.isEmpty {
                    print("[VideoExtractor] 直接解析成功，找到 \(sources.count) 个源")
                    return .success(sources)
                }
            } catch {
                print("[VideoExtractor] 直接解析失败: \(error)")
            }
        }

        // 使用 WebView 拦截
        return await extractWithWebView(url: episodeURL, rule: rule)
    }

    /// 使用 WKWebView 提取视频
    private func extractWithWebView(url: String, rule: AnimeRule) async -> VideoExtractionResult {
        // 先完成 WebView 设置（包括内容拦截规则的异步加载）
        await setupWebView(rule: rule)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.foundSources.removeAll()

            // 设置超时
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if self.continuation != nil {
                    print("[VideoExtractor] 提取超时")
                    self.finish(with: .timeout)
                }
            }

            // 加载页面
            if let requestURL = URL(string: url) {
                var request = URLRequest(url: requestURL)
                request.timeoutInterval = timeout

                // 添加规则自定义 headers
                if let headers = rule.headers {
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }

                // 添加 Referer（如果规则有指定）
                if let referer = rule.headers?["Referer"] {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }

                print("[VideoExtractor] 加载页面: \(url)")
                isLoading = true
                webView?.load(request)
            } else {
                finish(with: .error("Invalid URL"))
            }
        }
    }

    // MARK: - WebView 设置

    private func setupWebView(rule: AnimeRule) async {
        let config = WKWebViewConfiguration()

        // 允许媒体自动播放
        config.mediaTypesRequiringUserActionForPlayback = []

        // 配置用户内容控制器
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "VideoBridge")
        userContentController.add(self, name: "LogBridge")
        config.userContentController = userContentController

        // 注入视频拦截脚本
        let script = WKUserScript(
            source: videoInterceptorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(script)

        // 创建 WebView
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 360, height: 640), configuration: config)
        webView?.navigationDelegate = self
        webView?.isHidden = true

        // 设置 User-Agent (优先使用规则指定的)
        let userAgent: String
        if let ruleUserAgent = rule.userAgent, !ruleUserAgent.isEmpty {
            userAgent = ruleUserAgent
        } else {
            userAgent = userAgents.randomElement()!
        }
        webView?.customUserAgent = userAgent

        // 配置内容拦截规则（参考 Kazumi 的 ContentBlocker）
        await setupContentBlocking(for: config)
    }

    // MARK: - 内容拦截规则 (参考 Kazumi ContentBlocker)

    private func setupContentBlocking(for config: WKWebViewConfiguration) async {
        // 参考 Kazumi 的广告拦截规则
        // 注意：在 JSON 字符串中，反斜杠需要转义
        let blockRules = """
        [
            {
                "trigger": {
                    "url-filter": ".*devtools-detector.*"
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*googleads.*"
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*googlesyndication.com.*"
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*prestrain.html"
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*prestrain%2Ehtml"
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*adtrafficquality.*"
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*popunder.*"
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": ".*popup.*"
                },
                "action": {
                    "type": "block"
                }
            }
        ]
        """

        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "VideoAdBlocker",
                encodedContentRuleList: blockRules
            ) { ruleList, error in
                if let error = error {
                    print("[VideoExtractor] 内容拦截规则编译失败: \(error)")
                } else if let ruleList = ruleList {
                    config.userContentController.add(ruleList)
                    print("[VideoExtractor] 内容拦截规则已启用")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - 视频拦截脚本

    /// 参考 Kazumi 的 JavaScript 注入脚本（增强版）
    private var videoInterceptorScript: String {
        """
        (function() {
            'use strict';

            console.log('[VideoInterceptor] 脚本已加载');

            // 视频 URL 缓存（避免重复发送）
            const sentUrls = new Set();

            // 广告/追踪域名黑名单
            const blacklist = [
                'googleads', 'googlesyndication', 'google-analytics',
                'doubleclick', 'facebook', 'tracker', 'analytics',
                'adtrafficquality', 'devtools-detector', 'prestrain',
                'popup', 'popunder', 'cdn.jsdelivr.net', 'clarity.ms',
                'gtag', 'googletagmanager', 'baidu.com', 'hm.baidu.com'
            ];

            // 通知原生端
            function notifyNative(message) {
                try {
                    window.webkit.messageHandlers.LogBridge.postMessage(message);
                } catch(e) {}
            }

            // 检查 URL 是否有效
            function isValidVideoUrl(url) {
                if (!url || typeof url !== 'string') return false;
                if (url.startsWith('blob:')) return false;
                if (url.startsWith('data:')) return false;
                if (url.startsWith('javascript:')) return false;

                // 检查黑名单
                const lowerUrl = url.toLowerCase();
                for (const domain of blacklist) {
                    if (lowerUrl.includes(domain)) return false;
                }

                // 必须是有效的视频扩展名或包含视频特征
                const videoPatterns = [
                    '.m3u8', '.mp4', '.webm', '.mkv', '.ts',
                    'video/', 'application/x-mpegURL', 'application/vnd.apple.mpegurl'
                ];
                return videoPatterns.some(pattern => lowerUrl.includes(pattern));
            }

            // 发送视频 URL (用于从 video 标签/fetch 响应 URL 直接发现)
            function sendVideoURL(url, source) {
                if (!isValidVideoUrl(url)) return;
                sendRawVideoURL(url, source);
            }

            // 直接发送 URL (用于 M3U8 内容检测，跳过扩展名检查)
            function sendRawVideoURL(url, source) {
                if (!url || typeof url !== 'string') return;
                if (url.startsWith('blob:')) return;
                if (url.startsWith('data:')) return;
                if (url.startsWith('javascript:')) return;
                if (sentUrls.has(url)) return;

                // 检查黑名单
                const lowerUrl = url.toLowerCase();
                for (const domain of blacklist) {
                    if (lowerUrl.includes(domain)) return;
                }

                sentUrls.add(url);

                try {
                    window.webkit.messageHandlers.VideoBridge.postMessage({
                        type: 'video',
                        url: url,
                        source: source || 'unknown'
                    });
                    notifyNative('[' + (source || 'unknown') + '] 找到视频: ' + url);
                } catch(e) {}
            }

            // 拦截 Response.text() 和 Response.json()
            const _r_text = window.Response.prototype.text;
            window.Response.prototype.text = function() {
                return new Promise((resolve, reject) => {
                    _r_text.call(this).then((text) => {
                        resolve(text);
                        // 检测 M3U8 内容
                        if (text && text.trim().startsWith('#EXTM3U')) {
                            notifyNative('M3U8 响应: ' + this.url);
                            sendRawVideoURL(this.url, 'response.text');
                        }
                    }).catch(reject);
                });
            };

            // 拦截 fetch API
            const _fetch = window.fetch;
            window.fetch = function(...args) {
                const url = args[0];
                const urlString = typeof url === 'string' ? url : (url.url || url.toString());

                return _fetch.apply(this, args).then(response => {
                    // 检查响应 URL
                    if (isValidVideoUrl(response.url)) {
                        notifyNative('Fetch 视频响应: ' + response.url);
                        sendVideoURL(response.url, 'fetch.response');
                    }

                    // 克隆响应以读取内容
                    const clonedResponse = response.clone();
                    clonedResponse.text().then(text => {
                        if (text && text.trim().startsWith('#EXTM3U')) {
                            notifyNative('Fetch M3U8: ' + urlString);
                            sendRawVideoURL(urlString, 'fetch.m3u8');
                        }
                    }).catch(() => {});

                    return response;
                });
            };

            // 拦截 XMLHttpRequest
            const _open = window.XMLHttpRequest.prototype.open;
            const _send = window.XMLHttpRequest.prototype.send;

            window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                this._url = url;
                return _open.call(this, method, url, ...rest);
            };

            window.XMLHttpRequest.prototype.send = function(...args) {
                this.addEventListener('load', () => {
                    try {
                        let content = this.responseText;
                        if (content && content.trim().startsWith('#EXTM3U')) {
                            notifyNative('XHR M3U8: ' + this._url);
                            sendRawVideoURL(this._url, 'xhr.m3u8');
                        }
                    } catch(e) {}
                });
                return _send.apply(this, args);
            };

            // 递归注入 iframe
            function injectIntoIframe(iframe) {
                try {
                    const iframeWindow = iframe.contentWindow;
                    if (!iframeWindow || !iframeWindow.Response || !iframeWindow.XMLHttpRequest) return;

                    notifyNative('注入 iframe: ' + (iframe.src || 'inline'));

                    // 拦截 iframe 的 Response
                    const iframe_r_text = iframeWindow.Response.prototype.text;
                    iframeWindow.Response.prototype.text = function() {
                        return new Promise((resolve, reject) => {
                            iframe_r_text.call(this).then((text) => {
                                resolve(text);
                                if (text && text.trim().startsWith('#EXTM3U')) {
                                    notifyNative('iframe M3U8: ' + this.url);
                                    sendVideoURL(this.url, 'iframe.response');
                                }
                            }).catch(reject);
                        });
                    };

                    // 拦截 iframe 的 fetch
                    const iframe_fetch = iframeWindow.fetch;
                    iframeWindow.fetch = function(...args) {
                        const url = args[0];
                        const urlString = typeof url === 'string' ? url : (url.url || url.toString());

                        return iframe_fetch.apply(this, args).then(response => {
                            if (isValidVideoUrl(response.url)) {
                                notifyNative('iframe fetch 视频: ' + response.url);
                                sendVideoURL(response.url, 'iframe.fetch');
                            }
                            return response;
                        });
                    };

                    // 拦截 iframe 的 XHR
                    const iframe_xhr_open = iframeWindow.XMLHttpRequest.prototype.open;
                    const iframe_xhr_send = iframeWindow.XMLHttpRequest.prototype.send;

                    iframeWindow.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                        this._url = url;
                        return iframe_xhr_open.call(this, method, url, ...rest);
                    };

                    iframeWindow.XMLHttpRequest.prototype.send = function(...args) {
                        this.addEventListener('load', () => {
                            try {
                                let content = this.responseText;
                                if (content && content.trim().startsWith('#EXTM3U')) {
                                    notifyNative('iframe XHR M3U8: ' + this._url);
                                    sendVideoURL(this._url, 'iframe.xhr');
                                }
                            } catch(e) {}
                        });
                        return iframe_xhr_send.apply(this, args);
                    };

                    // 递归注入嵌套 iframe
                    setupIframeListenersInWindow(iframeWindow);
                } catch(e) {
                    console.error('iframe 注入失败:', e);
                }
            }

            // 在指定 window 中设置 iframe 监听
            function setupIframeListenersInWindow(targetWindow) {
                try {
                    const doc = targetWindow.document;
                    if (!doc) return;

                    doc.querySelectorAll('iframe').forEach(iframe => {
                        if (iframe.contentDocument) {
                            injectIntoIframe(iframe);
                        }
                        iframe.addEventListener('load', () => injectIntoIframe(iframe));
                    });
                } catch(e) {}
            }

            // 监听 iframe 变化
            function setupIframeListeners() {
                setupIframeListenersInWindow(window);

                const observer = new MutationObserver(mutations => {
                    mutations.forEach(mutation => {
                        if (mutation.type === 'childList') {
                            mutation.addedNodes.forEach(node => {
                                if (node.nodeName === 'IFRAME') {
                                    node.addEventListener('load', () => injectIntoIframe(node));
                                }
                                if (node.querySelectorAll) {
                                    node.querySelectorAll('iframe').forEach(iframe => {
                                        iframe.addEventListener('load', () => injectIntoIframe(iframe));
                                    });
                                }
                            });
                        }
                    });
                });

                if (document.body) {
                    observer.observe(document.body, { childList: true, subtree: true });
                } else {
                    document.addEventListener('DOMContentLoaded', () => {
                        observer.observe(document.body, { childList: true, subtree: true });
                    });
                }
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupIframeListeners);
            } else {
                setupIframeListeners();
            }

            // 扫描 video 元素
            function scanVideoElements() {
                document.querySelectorAll('video').forEach(video => {
                    // 检查 video 的 src
                    let src = video.getAttribute('src');
                    if (src && src.trim() !== '') {
                        notifyNative('video src: ' + src);
                        sendVideoURL(src, 'video.src');
                    }

                    // 检查 source 标签
                    const sources = video.getElementsByTagName('source');
                    for (let source of sources) {
                        src = source.getAttribute('src');
                        if (src && src.trim() !== '') {
                            notifyNative('video source: ' + src);
                            sendVideoURL(src, 'video.source');
                        }
                    }

                    // 检查 data-src (懒加载)
                    const dataSrc = video.getAttribute('data-src');
                    if (dataSrc && dataSrc.trim() !== '') {
                        notifyNative('video data-src: ' + dataSrc);
                        sendVideoURL(dataSrc, 'video.dataSrc');
                    }
                });

                // 检查常见播放器容器的 data 属性
                document.querySelectorAll('[data-video], [data-src], [data-url]').forEach(el => {
                    const videoUrl = el.getAttribute('data-video') ||
                                    el.getAttribute('data-src') ||
                                    el.getAttribute('data-url');
                    if (videoUrl && isValidVideoUrl(videoUrl)) {
                        notifyNative('data attribute: ' + videoUrl);
                        sendVideoURL(videoUrl, 'data.attribute');
                    }
                });
            }

            // 监听 video 元素变化
            const videoObserver = new MutationObserver((mutations) => {
                for (const mutation of mutations) {
                    if (mutation.type === 'attributes' && mutation.target.nodeName === 'VIDEO') {
                        scanVideoElements();
                        continue;
                    }
                    for (const node of mutation.addedNodes) {
                        if (node.nodeName === 'VIDEO') {
                            scanVideoElements();
                        }
                        if (node.querySelectorAll) {
                            node.querySelectorAll('video').forEach(scanVideoElements);
                        }
                    }
                }
            });

            if (document.body) {
                videoObserver.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src']
                });
                scanVideoElements();
            } else {
                document.addEventListener('DOMContentLoaded', () => {
                    videoObserver.observe(document.body, {
                        childList: true,
                        subtree: true,
                        attributes: true,
                        attributeFilter: ['src']
                    });
                    scanVideoElements();
                });
            }

            // 定期扫描
            setInterval(scanVideoElements, 1000);

            console.log('[VideoInterceptor] 初始化完成');
        })();
        """
    }

    // MARK: - 完成处理

    private func finish(with result: VideoExtractionResult) {
        timer?.invalidate()
        timer = nil
        isLoading = false

        if let continuation = self.continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        }

        // 清理 WebView
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    // MARK: - 轮询检查

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollVideoSource()
        }
    }

    private func pollVideoSource() {
        guard !foundSources.isEmpty || isLoading else { return }

        // 如果找到了视频源，可以结束
        if !foundSources.isEmpty {
            // 过滤掉可能的无效 URL
            let validSources = foundSources.filter { url in
                let lower = url.lowercased()
                // 排除广告/追踪域名
                let isAd = ["google", "facebook", "tracker", "analytics", "gtag", "baidu", "clarity.ms"].contains { lower.contains($0) }
                return !isAd
            }

            guard !validSources.isEmpty else { return }

            let sources = validSources.map { url in
                VideoSource(
                    quality: extractQuality(from: url) ?? "auto",
                    url: url,
                    type: url.contains(".m3u8") ? "hls" : "mp4",
                    label: nil
                )
            }

            print("[VideoExtractor] ✅ 找到 \(sources.count) 个有效视频源")
            for (index, source) in sources.enumerated() {
                print("[VideoExtractor]   [\(index + 1)] \(source.url.prefix(80))...")
            }

            finish(with: .success(sources))
        }
    }

    private func extractQuality(from url: String) -> String? {
        let patterns = ["(\\d{3,4})p", "(\\d{3,4})_", "quality=(\\w+)", "(\\d{3,4})\\."]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               let range = Range(match.range(at: 1), in: url) {
                return String(url[range])
            }
        }
        return nil
    }
}

// MARK: - WKNavigationDelegate

extension AnimeVideoExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[VideoExtractor] ✅ 页面加载完成")
        isLoading = false
        startPolling()

        // 获取页面信息
        webView.evaluateJavaScript("document.title") { [weak self] result, error in
            if let title = result as? String {
                print("[VideoExtractor] 📄 页面标题: \(title)")
            }
        }

        webView.evaluateJavaScript("document.querySelectorAll('iframe').length") { [weak self] result, error in
            if let count = result as? Int {
                print("[VideoExtractor] 📄 iframe 数量: \(count)")
            }
        }

        webView.evaluateJavaScript("document.querySelectorAll('video').length") { [weak self] result, error in
            if let count = result as? Int {
                print("[VideoExtractor] 📄 video 元素数量: \(count)")
            }
        }

        // 注入深度扫描脚本
        let scanScript = """
        (function() {
            console.log('[Scanner] 开始深度扫描...');

            // 扫描所有 iframe
            const iframes = document.querySelectorAll('iframe');
            console.log('[Scanner] 找到 ' + iframes.length + ' 个 iframe');

            iframes.forEach((iframe, index) => {
                let src = iframe.getAttribute('src') || iframe.getAttribute('data-src');
                if (src) {
                    try {
                        window.webkit.messageHandlers.LogBridge.postMessage('iframe[' + index + '] src: ' + src);
                    } catch(e) {}
                }
            });

            // 扫描所有 video 元素
            const videos = document.querySelectorAll('video');
            console.log('[Scanner] 找到 ' + videos.length + ' 个 video 元素');

            videos.forEach((video, index) => {
                let src = video.getAttribute('src') || video.getAttribute('data-src');
                if (src) {
                    try {
                        window.webkit.messageHandlers.LogBridge.postMessage('video[' + index + '] src: ' + src);
                        window.webkit.messageHandlers.VideoBridge.postMessage({
                            type: 'video',
                            url: src,
                            source: 'scan.video'
                        });
                    } catch(e) {}
                }
            });

            // 扫描包含视频 URL 的 data 属性
            document.querySelectorAll('*').forEach(el => {
                const attrs = ['data-video', 'data-src', 'data-url', 'data-play', 'data-link'];
                attrs.forEach(attr => {
                    const value = el.getAttribute(attr);
                    if (value && (value.includes('.m3u8') || value.includes('.mp4'))) {
                        try {
                            window.webkit.messageHandlers.LogBridge.postMessage('Found ' + attr + ': ' + value);
                            window.webkit.messageHandlers.VideoBridge.postMessage({
                                type: 'video',
                                url: value,
                                source: 'scan.' + attr
                            });
                        } catch(e) {}
                    }
                });
            });

            console.log('[Scanner] 扫描完成');
        })();
        """
        webView.evaluateJavaScript(scanScript) { result, error in
            if let error = error {
                print("[VideoExtractor] ⚠️ 扫描脚本执行失败: \(error)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[VideoExtractor] 页面加载失败: \(error)")
        if !foundSources.isEmpty {
            let sources = foundSources.map { url in
                VideoSource(
                    quality: extractQuality(from: url) ?? "auto",
                    url: url,
                    type: url.contains(".m3u8") ? "hls" : "mp4",
                    label: nil
                )
            }
            finish(with: .success(sources))
        } else {
            finish(with: .error(error.localizedDescription))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let url = navigationResponse.response.url?.absoluteString ?? ""
        let lowercasedURL = url.lowercased()

        // 黑名单过滤
        let blacklist = ["googleads", "googlesyndication", "doubleclick", "facebook",
                        "analytics", "tracker", "gtag", "clarity.ms", "baidu.com"]
        let isBlacklisted = blacklist.contains { lowercasedURL.contains($0) }

        // 检测 M3U8 响应
        if let mimeType = navigationResponse.response.mimeType {
            if (mimeType.contains("mpegurl") || lowercasedURL.contains(".m3u8")) && !isBlacklisted {
                print("[VideoExtractor] ✅ 检测到 M3U8: \(url)")
                foundSources.insert(url)
            }
        }

        // 检测视频响应
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let contentType = (httpResponse.allHeaderFields["Content-Type"] as? String ?? "").lowercased()
            if (contentType.contains("video/") || contentType.contains("application/x-mpegurl")) && !isBlacklisted {
                print("[VideoExtractor] ✅ 检测到视频响应: \(url)")
                foundSources.insert(url)
            }
        }

        // 日志：记录所有网络请求（用于调试）
        if !isBlacklisted && (lowercasedURL.contains(".mp4") || lowercasedURL.contains(".m3u8") ||
           lowercasedURL.contains("video") || lowercasedURL.contains("stream")) {
            print("[VideoExtractor] 📝 可疑 URL: \(url)")
        }

        decisionHandler(.allow)
    }

    // 拦截所有网络请求（iOS 15+ / macOS 12+）
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView, authenticationChallenge challenge: URLAuthenticationChallenge, shouldAllowDeprecatedTLS decisionHandler: @escaping (Bool) -> Void) {
        decisionHandler(true)
    }
}

// MARK: - WKScriptMessageHandler

extension AnimeVideoExtractor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "VideoBridge" {
            if let body = message.body as? [String: Any],
               let url = body["url"] as? String {
                let source = body["source"] as? String ?? "unknown"
                print("[VideoExtractor] ✅ JS 发现视频 [\(source)]: \(url.prefix(100))...")
                foundSources.insert(url)
            }
        } else if message.name == "LogBridge" {
            if let log = message.body as? String {
                // 过滤掉无关日志，只保留重要信息
                let lowerLog = log.lowercased()
                if lowerLog.contains("找到") || lowerLog.contains("m3u8") ||
                   lowerLog.contains("视频") || lowerLog.contains("error") ||
                   lowerLog.contains("失败") {
                    print("[VideoExtractor] 📝 JS: \(log)")
                }
            }
        }
    }
}
