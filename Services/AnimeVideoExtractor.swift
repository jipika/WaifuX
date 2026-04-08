import Foundation
import WebKit
import Combine

// MARK: - Video Extraction Result

enum VideoExtractionResult {
    case success([VideoSource])
    case error(String)
    case captcha
    case timeout
}

// MARK: - Anime Video Extractor

@MainActor
class AnimeVideoExtractor: NSObject, ObservableObject {
    static let shared = AnimeVideoExtractor()
    
    @Published var isLoading = false
    @Published var progressMessage = ""
    @Published var logMessages: [String] = []
    
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<VideoExtractionResult, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var videoFoundTask: Task<Void, Never>?
    private var resolveId = 0
    
    // Video source detection
    private var detectedSources: Set<String> = []
    private var isVideoFound = false
    private var currentRule: AnimeRule?
    
    // 使用共享的 WebsiteDataStore，确保验证码 WebView 中设置的 Cookie 能同步到后续 URLSession 请求
    // 注意：不再使用 nonPersistent()，因为那会导致 Cookie 隔离
    private let dataStore = WKWebsiteDataStore.default()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    
    /// 从剧集 URL 提取视频源（Kazumi 风格解析）
    /// - 使用独立的非持久化数据存储，避免 Cookie 污染
    func extractVideoSources(
        from episodeURL: String,
        rule: AnimeRule,
        timeout: TimeInterval = 30.0
    ) async -> VideoExtractionResult {
        // 取消之前的解析
        await cancelAndCleanup()
        
        // MARK: - 快速路径：检测视频文件直链
        // 某些源返回的 episodeURL 本身就是 .mp4/.m3u8 等视频文件直链，
        // 无需 WebView 解析（WebView 加载非 HTML 内容时 JS 脚本可能无法正常执行）
        if let directSource = detectDirectVideoURL(episodeURL) {
            addLog("🚀 检测到视频直链，跳过 WebView 解析")
            return .success([directSource])
        }
        
        resolveId += 1
        let currentResolveId = resolveId
        self.currentRule = rule
        
        isLoading = true
        progressMessage = "正在初始化解析器..."
        logMessages.removeAll()
        detectedSources.removeAll()
        isVideoFound = false
        
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            
            // 设置超时
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.handleTimeout(resolveId: currentResolveId)
            }
            
            // 设置 WebView（使用独立的数据存储）
            self.setupWebView(resolveId: currentResolveId)
            
            guard let url = URL(string: episodeURL) else {
                self.finish(with: .error("无效的视频链接"), resolveId: currentResolveId)
                return
            }
            
            addLog("开始解析: \(episodeURL)")
            
            // 同步规则相关的 Cookie（如果有）
            syncRuleCookiesToWebView(rule: rule, url: url)
            
            // 加载 URL
            var request = URLRequest(url: url, timeoutInterval: timeout)
            
            // 添加规则中的 headers
            if let headers = rule.headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            
            // 添加 User-Agent
            if let userAgent = rule.userAgent {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            
            // 添加 Referer
            let referer = rule.referer ?? rule.baseURL
            request.setValue(referer, forHTTPHeaderField: "Referer")
            
            // 添加 Cookie
            let cookieString = HTTPCookieStorage.shared.cookies(for: url)?.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") ?? ""
            if !cookieString.isEmpty {
                request.setValue(cookieString, forHTTPHeaderField: "Cookie")
                addLog("使用 Cookie: \(cookieString.prefix(50))...")
            }
            
            self.webView?.load(request)
        }
    }
    
    /// 取消当前解析（真正停止 WebView）
    func cancel() {
        Task { @MainActor in
            await cancelAndCleanup()
        }
    }
    
    /// 清理并取消所有操作
    private func cancelAndCleanup() async {
        resolveId += 1
        let cancelledResolveId = resolveId
        
        // 取消所有任务
        timeoutTask?.cancel()
        timeoutTask = nil
        videoFoundTask?.cancel()
        videoFoundTask = nil
        
        // 真正停止 WebView 加载
        if let webView = webView {
            webView.stopLoading()
            // 移除所有脚本处理器以避免回调
            let userContentController = webView.configuration.userContentController
            userContentController.removeAllScriptMessageHandlers()
            // 加载空白页以停止所有网络请求
            webView.loadHTMLString("", baseURL: nil)
        }
        
        // 清理状态
        webView = nil
        detectedSources.removeAll()
        isVideoFound = false
        currentRule = nil
        
        // 如果有挂起的 continuation，恢复它
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: .error("已取消"))
        }
        
        isLoading = false
        
        print("[AnimeVideoExtractor] 已取消解析 (resolveId: \(cancelledResolveId))")
    }
}

// MARK: - WebView Setup

private extension AnimeVideoExtractor {
    func setupWebView(resolveId: Int) {
        let config = WKWebViewConfiguration()
        
        // 启用 JavaScript
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // 使用独立的非持久化数据存储（关键修复！）
        // 这样每个视频解析都是干净的，不受之前解析的影响
        config.websiteDataStore = dataStore
        
        // 启用媒体播放（macOS 不需要用户操作）
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        #endif
        
        // 设置用户内容控制器
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "VideoBridge")
        userContentController.add(self, name: "LogBridge")
        config.userContentController = userContentController
        
        // 创建 WebView
        webView = WKWebView(frame: .zero, configuration: config)
        webView?.navigationDelegate = self
        webView?.isInspectable = true
        
        // 注入脚本
        injectKazumiScripts(resolveId: resolveId)
        
        // 设置内容拦截
        setupContentBlocking()
        
        print("[AnimeVideoExtractor] WebView 设置完成（使用独立数据存储）")
    }
    
    /// 同步规则相关的 Cookie 到 WebView
    func syncRuleCookiesToWebView(rule: AnimeRule, url: URL) {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let cookieStore = dataStore.httpCookieStore
        
        for cookie in cookies {
            cookieStore.setCookie(cookie)
        }
        
        if !cookies.isEmpty {
            addLog("同步 \(cookies.count) 个 Cookie 到 WebView")
        }
    }
    
    func setupContentBlocking() {
        let blockRules = """
        [
            {
                "trigger": {
                    "url-filter": ".*googleads.*",
                    "resource-type": ["document", "script"]
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": ".*googlesyndication\\.com.*",
                    "resource-type": ["document", "script"]
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": ".*doubleclick\\.net.*",
                    "resource-type": ["document", "script"]
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": ".*prestrain\\.html.*",
                    "resource-type": ["document"]
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": ".*devtools-detector.*",
                    "resource-type": ["script"]
                },
                "action": { "type": "block" }
            },
            {
                "trigger": {
                    "url-filter": ".*",
                    "resource-type": ["image"]
                },
                "action": { "type": "block" }
            }
        ]
        """
        
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "AdBlockingRules_\(resolveId)",
            encodedContentRuleList: blockRules
        ) { [weak self] ruleList, error in
            if let ruleList = ruleList {
                self?.webView?.configuration.userContentController.add(ruleList)
            }
        }
    }
}

// MARK: - Kazumi-Style Script Injection

private extension AnimeVideoExtractor {
    func injectKazumiScripts(resolveId: Int) {
        guard let webView = webView else { return }
        
        // 脚本 1: 网络拦截（在 document start 注入）
        let networkInterceptorScript = WKUserScript(
            source: Self.networkInterceptorScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        
        // 脚本 2: 视频元素扫描（在 document end 注入）
        let videoScannerScript = WKUserScript(
            source: Self.videoScannerScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        
        // 脚本 3: Iframe 注入器
        let iframeInjectorScript = WKUserScript(
            source: Self.iframeInjectorScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        
        // 脚本 4: 传统 iframe 提取器
        let legacyIframeScript = WKUserScript(
            source: Self.legacyIframeScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        
        let userContentController = webView.configuration.userContentController
        userContentController.addUserScript(networkInterceptorScript)
        userContentController.addUserScript(videoScannerScript)
        userContentController.addUserScript(iframeInjectorScript)
        userContentController.addUserScript(legacyIframeScript)
        
        addLog("所有脚本已注入 (4 个)")
    }
    
    // MARK: - JavaScript 脚本源码
    
    private static let networkInterceptorScriptSource = """
    (function() {
        'use strict';
        
        if (window.__kazumiNetworkInterceptorInstalled) return;
        window.__kazumiNetworkInterceptorInstalled = true;
        
        function sendToNative(message, handler) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
                window.webkit.messageHandlers[handler].postMessage(message);
            }
        }
        
        function sendLog(message) {
            sendToNative(message, 'LogBridge');
        }
        
        function sendVideo(url) {
            if (!url || url.includes('googleads') || url.includes('googlesyndication')) return;
            sendToNative(url, 'VideoBridge');
        }
        
        function isM3U8(text) {
            return text && text.trim().startsWith('#EXTM3U');
        }
        
        function isVideoURL(url) {
            if (!url) return false;
            const videoExtensions = ['.m3u8', '.mp4', '.webm', '.mkv', '.ts', '.flv', '.mov'];
            const lowerUrl = url.toLowerCase();
            return videoExtensions.some(ext => lowerUrl.includes(ext)) || 
                   lowerUrl.includes('video') ||
                   lowerUrl.includes('stream') ||
                   lowerUrl.includes('playback');
        }
        
        sendLog('Kazumi 网络拦截器已加载: ' + window.location.href);
        
        // 拦截 fetch
        const originalFetch = window.fetch;
        window.fetch = function(...args) {
            const url = args[0];
            if (typeof url === 'string' && isVideoURL(url)) {
                sendLog('Fetch 检测到视频 URL: ' + url);
                sendVideo(url);
            }
            
            return originalFetch.apply(this, args).then(response => {
                const clonedResponse = response.clone();
                clonedResponse.text().then(text => {
                    if (isM3U8(text)) {
                        sendLog('M3U8 在 fetch 响应中发现: ' + url);
                        sendVideo(url);
                    }
                }).catch(() => {});
                return response;
            });
        };
        
        // 拦截 XMLHttpRequest
        const originalXHROpen = window.XMLHttpRequest.prototype.open;
        window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            this._url = url;
            if (typeof url === 'string' && isVideoURL(url)) {
                sendLog('XHR 检测到视频 URL: ' + url);
                sendVideo(url);
            }
            
            this.addEventListener('load', function() {
                try {
                    const responseText = this.responseText;
                    if (isM3U8(responseText)) {
                        sendLog('M3U8 在 XHR 响应中发现: ' + this._url);
                        sendVideo(this._url);
                    }
                } catch(e) {}
            });
            
            return originalXHROpen.call(this, method, url, ...rest);
        };
        
        // 拦截 createElement
        const originalCreateElement = document.createElement;
        document.createElement = function(tagName) {
            const element = originalCreateElement.call(document, tagName);
            if (tagName.toLowerCase() === 'iframe') {
                const originalSrcSetter = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src')?.set;
                if (originalSrcSetter) {
                    Object.defineProperty(element, 'src', {
                        set: function(value) {
                            sendLog('Iframe src 设置: ' + value);
                            if (isVideoURL(value)) {
                                sendVideo(value);
                            }
                            return originalSrcSetter.call(this, value);
                        },
                        get: function() {
                            return this.getAttribute('src');
                        }
                    });
                }
            }
            return element;
        };
    })();
    """
    
    private static let videoScannerScriptSource = """
    (function() {
        'use strict';
        
        if (window.__kazumiVideoScannerInstalled) return;
        window.__kazumiVideoScannerInstalled = true;
        
        function sendToNative(message, handler) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
                window.webkit.messageHandlers[handler].postMessage(message);
            }
        }
        
        function sendLog(message) {
            sendToNative(message, 'LogBridge');
        }
        
        function sendVideo(url) {
            if (!url || url.startsWith('blob:') || url.includes('googleads')) return;
            sendToNative(url, 'VideoBridge');
        }
        
        function processVideoElement(video) {
            sendLog('扫描视频元素...');
            
            // 检查 src 属性
            let src = video.getAttribute('src');
            if (src && src.trim() !== '' && !src.startsWith('blob:')) {
                sendLog('VIDEO src 找到: ' + src);
                sendVideo(src);
                return;
            }
            
            // 检查 currentSrc 属性
            if (video.currentSrc && video.currentSrc.trim() !== '' && !video.currentSrc.startsWith('blob:')) {
                sendLog('VIDEO currentSrc 找到: ' + video.currentSrc);
                sendVideo(video.currentSrc);
                return;
            }
            
            // 检查 source 元素
            const sources = video.getElementsByTagName('source');
            for (let source of sources) {
                src = source.getAttribute('src');
                if (src && src.trim() !== '' && !src.startsWith('blob:')) {
                    sendLog('VIDEO source 标签找到: ' + src);
                    sendVideo(src);
                    return;
                }
            }
            
            // 检查 data-src（懒加载）
            src = video.getAttribute('data-src');
            if (src && src.trim() !== '' && !src.startsWith('blob:')) {
                sendLog('VIDEO data-src 找到: ' + src);
                sendVideo(src);
            }
        }
        
        // 处理现有视频
        sendLog('视频扫描器已加载，检查现有视频...');
        document.querySelectorAll('video').forEach(processVideoElement);
        
        // 设置 MutationObserver
        const observer = new MutationObserver((mutations) => {
            mutations.forEach(mutation => {
                if (mutation.type === 'attributes' && mutation.target.nodeName === 'VIDEO') {
                    if (mutation.attributeName === 'src' || mutation.attributeName === 'data-src') {
                        processVideoElement(mutation.target);
                    }
                }
                
                mutation.addedNodes.forEach(node => {
                    if (node.nodeName === 'VIDEO') {
                        sendLog('新视频元素检测到');
                        processVideoElement(node);
                    }
                    if (node.querySelectorAll) {
                        node.querySelectorAll('video').forEach(processVideoElement);
                    }
                });
            });
        });
        
        if (document.body) {
            observer.observe(document.body, {
                childList: true,
                subtree: true,
                attributes: true,
                attributeFilter: ['src', 'data-src']
            });
            sendLog('MutationObserver 已启动');
        }
        
        // 定期检查 iframe 中的视频
        function checkIframes() {
            document.querySelectorAll('iframe').forEach(iframe => {
                try {
                    if (iframe.contentDocument) {
                        iframe.contentDocument.querySelectorAll('video').forEach(processVideoElement);
                    }
                } catch(e) {}
            });
        }
        
        setInterval(checkIframes, 2000);
    })();
    """
    
    private static let iframeInjectorScriptSource = """
    (function() {
        'use strict';
        
        if (window.__kazumiIframeInjectorInstalled) return;
        window.__kazumiIframeInjectorInstalled = true;
        
        function sendToNative(message, handler) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
                window.webkit.messageHandlers[handler].postMessage(message);
            }
        }
        
        function sendLog(message) {
            sendToNative(message, 'LogBridge');
        }
        
        function sendVideo(url) {
            if (!url || url.startsWith('blob:') || url.includes('googleads')) return;
            sendToNative(url, 'VideoBridge');
        }
        
        function isVideoURL(url) {
            if (!url) return false;
            const videoExtensions = ['.m3u8', '.mp4', '.webm', '.mkv', '.ts', '.flv', '.mov'];
            const lowerUrl = url.toLowerCase();
            return videoExtensions.some(ext => lowerUrl.includes(ext));
        }
        
        function injectIntoIframe(iframe) {
            if (iframe.__kazumiInjected) return;
            iframe.__kazumiInjected = true;
            
            try {
                const iframeWindow = iframe.contentWindow;
                const iframeDoc = iframe.contentDocument;
                
                if (!iframeWindow || !iframeDoc) {
                    sendLog('无法访问 iframe 内容（跨域）');
                    return;
                }
                
                sendLog('注入 iframe: ' + iframe.src);
                
                if (!iframeWindow.__kazumiInjected) {
                    iframeWindow.__kazumiInjected = true;
                    
                    // 拦截 iframe 中的 fetch
                    const originalFetch = iframeWindow.fetch;
                    iframeWindow.fetch = function(...args) {
                        const url = args[0];
                        if (typeof url === 'string' && isVideoURL(url)) {
                            sendLog('Iframe fetch 检测到: ' + url);
                            sendVideo(url);
                        }
                        return originalFetch.apply(this, args);
                    };
                    
                    // 拦截 iframe 中的 XHR
                    const originalXHROpen = iframeWindow.XMLHttpRequest.prototype.open;
                    iframeWindow.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                        if (typeof url === 'string' && isVideoURL(url)) {
                            sendLog('Iframe XHR 检测到: ' + url);
                            sendVideo(url);
                        }
                        return originalXHROpen.call(this, method, url, ...rest);
                    };
                }
                
                // 扫描 iframe 中的视频
                iframeDoc.querySelectorAll('video').forEach(video => {
                    const src = video.getAttribute('src') || video.currentSrc;
                    if (src && !src.startsWith('blob:')) {
                        sendLog('Iframe 视频找到: ' + src);
                        sendVideo(src);
                    }
                });
                
                // 递归注入嵌套 iframe
                iframeDoc.querySelectorAll('iframe').forEach(injectIntoIframe);
                
                // 监视新 iframe
                const observer = new MutationObserver((mutations) => {
                    mutations.forEach(mutation => {
                        mutation.addedNodes.forEach(node => {
                            if (node.nodeName === 'IFRAME') {
                                injectIntoIframe(node);
                            }
                            if (node.querySelectorAll) {
                                node.querySelectorAll('iframe').forEach(injectIntoIframe);
                            }
                        });
                    });
                });
                
                observer.observe(iframeDoc.body, {
                    childList: true,
                    subtree: true
                });
                
            } catch(e) {
                sendLog('Iframe 注入错误: ' + e.message);
            }
        }
        
        function injectAllIframes() {
            document.querySelectorAll('iframe').forEach(injectIntoIframe);
        }
        
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', injectAllIframes);
        } else {
            injectAllIframes();
        }
        
        const observer = new MutationObserver((mutations) => {
            mutations.forEach(mutation => {
                mutation.addedNodes.forEach(node => {
                    if (node.nodeName === 'IFRAME') {
                        sendLog('新 iframe 检测到: ' + node.src);
                        injectIntoIframe(node);
                    }
                    if (node.querySelectorAll) {
                        node.querySelectorAll('iframe').forEach(injectIntoIframe);
                    }
                });
            });
        });
        
        if (document.body) {
            observer.observe(document.body, {
                childList: true,
                subtree: true
            });
        } else {
            document.addEventListener('DOMContentLoaded', () => {
                observer.observe(document.body, {
                    childList: true,
                    subtree: true
                });
            });
        }
        
        sendLog('Iframe 注入器已加载');
    })();
    """
    
    private static let legacyIframeScriptSource = """
    (function() {
        'use strict';
        
        function sendToNative(message, handler) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
                window.webkit.messageHandlers[handler].postMessage(message);
            }
        }
        
        function sendLog(message) {
            sendToNative(message, 'LogBridge');
        }
        
        function sendVideo(url) {
            sendToNative(url, 'VideoBridge');
        }
        
        sendLog('传统 iframe 扫描器已加载');
        
        const iframes = document.getElementsByTagName('iframe');
        sendLog('找到 ' + iframes.length + ' 个 iframe');
        
        for (let i = 0; i < iframes.length; i++) {
            const iframe = iframes[i];
            const src = iframe.getAttribute('src');
            if (src && src.trim() !== '') {
                sendLog('Iframe ' + i + ' src: ' + src);
                if (src.includes('http') && !src.includes('googleads')) {
                    sendVideo(src);
                }
            }
        }
    })();
    """
}

// MARK: - JavaScript Message Handling

extension AnimeVideoExtractor: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            switch message.name {
            case "LogBridge":
                if let log = message.body as? String {
                    self.addLog(log)
                }
                
            case "VideoBridge":
                if let urlString = message.body as? String {
                    self.handleVideoURL(urlString)
                }
                
            default:
                break
            }
        }
    }
    
    private func handleVideoURL(_ urlString: String) {
        // 避免重复
        guard !detectedSources.contains(urlString) else {
            addLog("⚠️ 重复视频 URL，跳过: \(urlString.prefix(50))")
            return
        }
        detectedSources.insert(urlString)
        
        addLog("📥 收到 VideoBridge 消息: \(urlString.prefix(80))...")
        
        // 忽略 blob URL
        guard !urlString.lowercased().hasPrefix("blob:") else {
            addLog("⚠️ 忽略 blob URL")
            return
        }
        
        // 检查是否是有效视频 URL
        let lowercased = urlString.lowercased()
        let isM3U8 = lowercased.contains(".m3u8") || lowercased.contains("application/vnd.apple.mpegurl")
        let isMP4 = lowercased.contains(".mp4") || lowercased.contains("video/mp4")
        let isTS = lowercased.contains(".ts") || lowercased.contains("video/MP2T")
        let isFLV = lowercased.contains(".flv")
        let isWebM = lowercased.contains(".webm")
        let isMKV = lowercased.contains(".mkv")
        let isMPD = lowercased.contains(".mpd")
        let isHLS = lowercased.contains("/hls/") || lowercased.contains("format=m3u8") || lowercased.contains("type=m3u8")
        
        // CDN 直链检测：某些 CDN（字节火山引擎、阿里 OSS、腾讯 COS 等）的签名链接
        // 路径不含扩展名，通过域名特征 + 签名参数识别
        let isCDNDirectLink = lowercased.contains("tos-cn-") ||          // 字节跳动 CDN
                               lowercased.contains("imcloud-file-sign") ||  // 字节火山引擎
                               lowercased.contains("bytedos.com") ||
                               lowercased.contains(".aliyuncs.com") ||     // 阿里云 OSS
                               lowercased.contains(".cos.") ||              // 腾讯云 COS
                               lowercased.contains("myqcloud.com") ||      // 腾讯云
                               lowercased.contains("x-expires=") ||         // CDN 过期签名
                               lowercased.contains("x-oss-expires=") ||    // 阿里 OSS 签名
                               (lowercased.contains("sign=") && (lowercased.contains("cdn") || lowercased.contains("object")))
        
        guard isM3U8 || isMP4 || isTS || isFLV || isWebM || isMKV || isMPD || isHLS || lowercased.contains("video") || isCDNDirectLink else {
            addLog("⚠️ URL 格式不符合视频特征，继续等待")
            return
        }
        
        // 确定质量标签和类型
        var quality = "Unknown"
        var type = "mp4"
        
        if isM3U8 || isHLS {
            quality = "Auto"
            type = "m3u8"
        } else if isMPD {
            quality = "Auto"
            type = "mpd"
        } else if isMP4 {
            if lowercased.contains("1080") || lowercased.contains("fhd") {
                quality = "1080P"
            } else if lowercased.contains("720") || lowercased.contains("hd") {
                quality = "720P"
            } else if lowercased.contains("480") || lowercased.contains("sd") {
                quality = "480P"
            } else {
                quality = "MP4"
            }
            type = "mp4"
        } else if isFLV {
            quality = "FLV"
            type = "flv"
        } else if isWebM {
            quality = "WebM"
            type = "webm"
        } else if isMKV {
            quality = "MKV"
            type = "mkv"
        }
        
        // 创建 VideoSource
        let source = VideoSource(
            quality: quality,
            url: urlString,
            type: type,
            label: nil
        )
        
        // 取消之前的延迟任务
        videoFoundTask?.cancel()
        
        // 标记视频已找到
        isVideoFound = true
        progressMessage = "找到视频源: \(quality)"
        
        // 短暂延迟以可能找到更高质量的视频源
        let currentResolveId = self.resolveId
        videoFoundTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000) // 0.8秒
            
            // 检查是否仍然有效
            guard !Task.isCancelled,
                  self.resolveId == currentResolveId,
                  self.isVideoFound else { return }
            
            let sources = [source]
            self.finish(with: .success(sources), resolveId: currentResolveId)
        }
    }
}

// MARK: - Navigation Delegate

extension AnimeVideoExtractor: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        Task { @MainActor in
            self.progressMessage = "正在加载页面..."
            self.addLog("页面开始加载")
        }
    }
    
    nonisolated func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        Task { @MainActor in
            self.progressMessage = "页面加载完成，扫描视频..."
            self.addLog("✅ 页面加载完成")
            
            // 页面加载完成后注入额外脚本
            self.injectPostLoadScripts()
            
            // 设置视频检测回退超时
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000) // 8秒
                if !self.isVideoFound && self.continuation != nil && self.resolveId > 0 {
                    self.addLog("⚠️ 8秒内未检测到视频，继续等待...")
                }
            }
        }
    }
    
    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            self.addLog("❌ 页面加载失败: \(error.localizedDescription)")
            if !self.isVideoFound {
                self.finish(
                    with: .error("页面加载失败: \(error.localizedDescription)"),
                    resolveId: self.resolveId
                )
            }
        }
    }
    
    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            // 检查是否是验证码相关的错误
            let errorDescription = error.localizedDescription.lowercased()
            if errorDescription.contains("captcha") ||
               errorDescription.contains("验证") ||
               errorDescription.contains("challenge") {
                self.addLog("⚠️ 检测到验证码页面")
                self.finish(with: .captcha, resolveId: self.resolveId)
                return
            }
            
            self.addLog("❌ 页面加载失败: \(error.localizedDescription)")
            if !self.isVideoFound {
                self.finish(
                    with: .error("页面加载失败: \(error.localizedDescription)"),
                    resolveId: self.resolveId
                )
            }
        }
    }
}

// MARK: - Post-Load Scripts

private extension AnimeVideoExtractor {
    func injectPostLoadScripts() {
        // 强制播放隐藏的视频（某些网站初始隐藏播放器）
        let forcePlayScript = """
        (function() {
            document.querySelectorAll('video').forEach(v => {
                v.style.display = 'block';
                v.style.visibility = 'visible';
                v.style.opacity = '1';
                v.muted = true;
                v.play().catch(() => {});
            });
        })();
        """
        
        webView?.evaluateJavaScript(forcePlayScript, completionHandler: nil)
        
        // 移除常见的反调试器检查
        let antiDebuggerScript = """
        (function() {
            window.debugger = function() {};
            const originalFunction = Function;
            window.Function = new Proxy(originalFunction, {
                construct(target, args) {
                    const code = args.join('');
                    if (code.includes('debugger')) {
                        return function() {};
                    }
                    return new target(...args);
                }
            });
        })();
        """
        
        webView?.evaluateJavaScript(antiDebuggerScript, completionHandler: nil)
    }
}

// MARK: - Helper Methods

private extension AnimeVideoExtractor {
    func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)"
        logMessages.append(logMessage)
        print("🎬 [VideoExtractor] \(message)")
    }
    
    // MARK: - 直链检测
    
    /// 检测 URL 是否是视频文件直链（.mp4, .m3u8, .ts 等）
    /// 如果是，直接返回 VideoSource；否则返回 nil 走 WebView 解析
    private func detectDirectVideoURL(_ urlString: String) -> VideoSource? {
        guard let url = URL(string: urlString) else { return nil }
        
        let lowerPath = url.path.lowercased()
        
        // 通过文件扩展名判断
        let videoExtensions: [(ext: String, type: String)] = [
            (".mp4", "mp4"),
            (".m3u8", "m3u8"),
            (".ts", "ts"),
            (".flv", "flv"),
            (".webm", "webm"),
            (".mkv", "mkv"),
            (".mpd", "mpd"),
        ]
        
        for item in videoExtensions where lowerPath.hasSuffix(item.ext) {
            let quality = inferQuality(from: urlString, type: item.ext)
            addLog("🎯 直链检测命中: \(item.ext) → \(quality)")
            return VideoSource(
                quality: quality,
                url: urlString,
                type: item.type,
                label: nil
            )
        }
        
        // 通过 URL 路径特征判断（如包含 /video/, /playback/, /hls/ 等）
        let lowerURL = urlString.lowercased()
        if lowerURL.contains("/hls/") || lowerURL.contains("format=m3u8") || lowerURL.contains("type=m3u8") {
            addLog("🎯 直链检测命中: HLS 特征路径")
            return VideoSource(
                quality: "Auto",
                url: urlString,
                type: "m3u8",
                label: nil
            )
        }
        
        // CDN 签名直链检测：无扩展名但通过域名/参数特征识别为视频文件
        let isCDNVideoLink: Bool = {
            lowerURL.contains("tos-cn-") ||          // 字节跳动 CDN
            lowerURL.contains("imcloud-file-sign") ||  // 字节火山引擎
            lowerURL.contains("bytedos.com") ||
            lowerURL.contains(".aliyuncs.com") ||     // 阿里云 OSS
            lowerURL.contains(".cos.") ||              // 腾讯云 COS
            lowerURL.contains("myqcloud.com") ||      // 腾讯云
            lowerURL.contains("x-expires=")             // CDN 过期签名参数
        }()
        
        if isCDNVideoLink {
            addLog("🎯 直链检测命中: CDN 签名视频链接")
            return VideoSource(
                quality: "MP4",
                url: urlString,
                type: "mp4",
                label: nil
            )
        }
        
        return nil
    }
    
    /// 根据推断质量标签
    private func inferQuality(from urlString: String, type: String) -> String {
        let lower = urlString.lowercased()
        
        if type == "m3u8" { return "Auto" }
        if type == "mpd" { return "Auto" }
        if type == "mp4" {
            if lower.contains("1080") || lower.contains("fhd") { return "1080P" }
            if lower.contains("720") || lower.contains("hd") { return "720P" }
            if lower.contains("480") || lower.contains("sd") { return "480P" }
            return "MP4"
        }
        return type.uppercased()
    }
    
    func handleTimeout(resolveId: Int) async {
        guard resolveId == self.resolveId else { return }
        
        if isVideoFound {
            // 已找到视频，忽略超时
            return
        }
        
        addLog("❌ 解析超时")
        finish(with: .timeout, resolveId: resolveId)
    }
    
    func finish(with result: VideoExtractionResult, resolveId: Int) {
        // 严格检查 resolveId，防止竞态条件
        guard resolveId == self.resolveId else {
            print("[AnimeVideoExtractor] 忽略过期结果 (resolveId: \(resolveId), current: \(self.resolveId))")
            return
        }
        
        // 取消所有任务
        timeoutTask?.cancel()
        timeoutTask = nil
        videoFoundTask?.cancel()
        videoFoundTask = nil
        
        isLoading = false
        
        switch result {
        case .success(let sources):
            progressMessage = "找到 \(sources.count) 个视频源"
            addLog("✅ 解析完成，找到 \(sources.count) 个视频源")
        case .error(let error):
            progressMessage = error
            addLog("❌ \(error)")
        case .captcha:
            progressMessage = "需要验证码验证"
            addLog("⛔ 需要验证码")
        case .timeout:
            progressMessage = "视频解析超时"
            addLog("⏱️ 解析超时")
        }
        
        // 清理 WebView
        cleanupWebView()
        
        // 恢复 continuation
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: result)
        }
    }
    
    /// 安全地清理 WebView 资源
    private func cleanupWebView() {
        // 停止加载
        webView?.stopLoading()
        
        // 移除所有脚本处理器
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        
        // 加载空白页以停止所有 JavaScript 执行
        webView?.loadHTMLString("", baseURL: nil)
        
        // 释放引用
        webView = nil
    }
}
