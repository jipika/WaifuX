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
    private var resolveId = 0
    
    // Video source detection
    private var detectedSources: Set<String> = []
    private var isVideoFound = false
    private var currentRule: AnimeRule?
    
    private override init() {
        super.init()
    }
    
    // Note: cleanup() must be called manually before deinit
    // deinit cannot call MainActor-isolated methods in Swift 6
    
    @MainActor
    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        detectedSources.removeAll()
        isVideoFound = false
        currentRule = nil
    }
}

// MARK: - Public Methods

extension AnimeVideoExtractor {
    /// Extract video sources from episode URL using Kazumi-style parsing
    func extractVideoSources(from episodeURL: String, rule: AnimeRule, timeout: TimeInterval = 30.0) async -> VideoExtractionResult {
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
            
            // Setup timeout
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.handleTimeout(resolveId: currentResolveId)
            }
            
            // Setup and load WebView
            self.setupWebView()
            
            guard let url = URL(string: episodeURL) else {
                self.finish(with: .error("无效的视频链接"), resolveId: currentResolveId)
                return
            }
            
            addLog("开始解析: \(episodeURL)")
            
            // Inject scripts before loading
            self.injectKazumiScripts(resolveId: currentResolveId)
            
            // Load the URL
            var request = URLRequest(url: url, timeoutInterval: timeout)
            
            // Add headers from rule
            if let headers = rule.headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            
            // Add User-Agent from rule
            if let userAgent = rule.userAgent {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            
            self.webView?.load(request)
        }
    }
    
    func cancel() {
        resolveId += 1
        finish(with: .error("已取消"), resolveId: resolveId)
    }
}

// MARK: - WebView Setup

private extension AnimeVideoExtractor {
    func setupWebView() {
        let config = WKWebViewConfiguration()
        
        // Enable JavaScript
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // Use default data store to share cookies with verification WebView
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        // Enable media playback (macOS doesn't require user action)
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        #endif
        
        // Setup user content controller
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "VideoBridge")
        userContentController.add(self, name: "LogBridge")
        config.userContentController = userContentController
        
        // Sync cookies from shared storage to WebView
        syncCookiesToWebView(config: config)
        
        // Create WebView
        webView = WKWebView(frame: .zero, configuration: config)
        webView?.navigationDelegate = self
        webView?.isInspectable = true
        
        // Setup content blocking for ads
        setupContentBlocking()
    }
    
    func syncCookiesToWebView(config: WKWebViewConfiguration) {
        // 将 HTTPCookieStorage 中的 Cookie 同步到 WKWebView
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        for cookie in cookies {
            config.websiteDataStore.httpCookieStore.setCookie(cookie)
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
            forIdentifier: "AdBlockingRules",
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
        
        // Script 1: Network Interception (injected at document start)
        let networkInterceptorScript = #"""
        (function() {
            'use strict';
            
            window.__kazumiInjected = true;
            
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
                const videoExtensions = ['.m3u8', '.mp4', '.webm', '.mkv', '.ts', '.flv', '.mov', '.mpd'];
                const lowerUrl = url.toLowerCase();
                return videoExtensions.some(ext => lowerUrl.includes(ext)) || 
                       lowerUrl.includes('video') ||
                       lowerUrl.includes('stream') ||
                       lowerUrl.includes('playback') ||
                       lowerUrl.includes('play') ||
                       lowerUrl.includes('hls') ||
                       lowerUrl.includes('dash');
            }
            
            sendLog('Kazumi network interceptor loaded: ' + window.location.href);
            
            // Intercept fetch
            const originalFetch = window.fetch;
            window.fetch = function(...args) {
                const url = args[0];
                if (typeof url === 'string' && isVideoURL(url)) {
                    sendLog('Fetch detected video URL: ' + url);
                    sendVideo(url);
                }
                
                return originalFetch.apply(this, args).then(response => {
                    const clonedResponse = response.clone();
                    clonedResponse.text().then(text => {
                        if (isM3U8(text)) {
                            sendLog('M3U8 found in fetch response: ' + url);
                            sendVideo(url);
                        }
                    }).catch(() => {});
                    return response;
                });
            };
            
            // Intercept XMLHttpRequest
            const originalXHROpen = window.XMLHttpRequest.prototype.open;
            window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                this._url = url;
                if (typeof url === 'string' && isVideoURL(url)) {
                    sendLog('XHR detected video URL: ' + url);
                    sendVideo(url);
                }
                
                this.addEventListener('load', function() {
                    try {
                        const responseText = this.responseText;
                        if (isM3U8(responseText)) {
                            sendLog('M3U8 found in XHR response: ' + this._url);
                            sendVideo(this._url);
                        }
                    } catch(e) {}
                });
                
                return originalXHROpen.call(this, method, url, ...rest);
            };
            
            // Intercept WebSocket
            const OriginalWebSocket = window.WebSocket;
            window.WebSocket = function(url, protocols) {
                sendLog('WebSocket created: ' + url);
                const ws = new OriginalWebSocket(url, protocols);
                ws.addEventListener('message', function(event) {
                    const data = event.data;
                    if (typeof data === 'string') {
                        const matches = data.match(/(https?:\/\/[^\s"'<>]+\.(?:m3u8|mp4|webm|ts|flv|mov|mkv|mpd))/gi);
                        if (matches) {
                            matches.forEach(match => sendVideo(match));
                        }
                    }
                });
                return ws;
            };
            window.WebSocket.prototype = OriginalWebSocket.prototype;
            
            // Intercept sendBeacon
            const originalSendBeacon = navigator.sendBeacon;
            navigator.sendBeacon = function(url, data) {
                if (typeof url === 'string' && isVideoURL(url)) {
                    sendLog('sendBeacon detected video URL: ' + url);
                    sendVideo(url);
                }
                if (originalSendBeacon) {
                    return originalSendBeacon.call(navigator, url, data);
                }
                return true;
            };
            
            // Intercept HTMLMediaElement src setter (covers video and audio)
            try {
                const originalSrcSetter = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src')?.set;
                if (originalSrcSetter) {
                    Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                        set: function(value) {
                            sendLog('Media src set: ' + value);
                            if (isVideoURL(value) || value.startsWith('blob:')) {
                                sendVideo(value);
                            }
                            return originalSrcSetter.call(this, value);
                        },
                        get: function() {
                            return this.getAttribute('src');
                        }
                    });
                }
            } catch(e) {}
            
            // Intercept createElement for iframes
            const originalCreateElement = document.createElement;
            document.createElement = function(tagName) {
                const element = originalCreateElement.call(document, tagName);
                if (tagName.toLowerCase() === 'iframe') {
                    const originalSrcSetter = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src')?.set;
                    if (originalSrcSetter) {
                        Object.defineProperty(element, 'src', {
                            set: function(value) {
                                sendLog('Iframe src set: ' + value);
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
            
            // PerformanceObserver for resource loading
            if (window.PerformanceObserver) {
                try {
                    const perfObserver = new PerformanceObserver((list) => {
                        list.getEntries().forEach(entry => {
                            if (entry.initiatorType === 'video' || entry.initiatorType === 'xmlhttprequest' || entry.initiatorType === 'fetch') {
                                if (isVideoURL(entry.name)) {
                                    sendLog('PerformanceObserver detected: ' + entry.name);
                                    sendVideo(entry.name);
                                }
                            }
                        });
                    });
                    perfObserver.observe({ entryTypes: ['resource'] });
                } catch(e) {}
            }
        })();
        """#
        
        // Script 2: Video Element Scanner (injected at document end)
        let videoScannerScript = #"""
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
                if (!url || url.includes('googleads')) return;
                sendToNative(url, 'VideoBridge');
            }
            
            function processVideoElement(video) {
                const attrs = ['src', 'currentSrc', 'data-src', 'data-url', 'data-video', 'data-original'];
                for (const attr of attrs) {
                    let value;
                    if (attr === 'currentSrc') {
                        value = video.currentSrc;
                    } else {
                        value = video.getAttribute(attr);
                    }
                    if (value && value.trim() !== '') {
                        sendLog('VIDEO ' + attr + ' found: ' + value);
                        sendVideo(value);
                    }
                }
                
                const sources = video.getElementsByTagName('source');
                for (let source of sources) {
                    const src = source.getAttribute('src');
                    if (src && src.trim() !== '') {
                        sendLog('VIDEO source tag found: ' + src);
                        sendVideo(src);
                    }
                }
            }
            
            function processAudioElement(audio) {
                const src = audio.getAttribute('src') || audio.currentSrc;
                if (src && src.trim() !== '') {
                    sendLog('AUDIO src found: ' + src);
                    sendVideo(src);
                }
            }
            
            sendLog('Video scanner loaded, checking existing videos...');
            document.querySelectorAll('video').forEach(processVideoElement);
            document.querySelectorAll('audio').forEach(processAudioElement);
            
            const observer = new MutationObserver((mutations) => {
                mutations.forEach(mutation => {
                    if (mutation.type === 'attributes') {
                        if (mutation.target.nodeName === 'VIDEO') {
                            processVideoElement(mutation.target);
                        } else if (mutation.target.nodeName === 'AUDIO') {
                            processAudioElement(mutation.target);
                        }
                    }
                    
                    mutation.addedNodes.forEach(node => {
                        if (node.nodeName === 'VIDEO') {
                            sendLog('New video element detected');
                            processVideoElement(node);
                        } else if (node.nodeName === 'AUDIO') {
                            sendLog('New audio element detected');
                            processAudioElement(node);
                        }
                        if (node.querySelectorAll) {
                            node.querySelectorAll('video').forEach(processVideoElement);
                            node.querySelectorAll('audio').forEach(processAudioElement);
                        }
                    });
                });
            });
            
            if (document.body) {
                observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src', 'data-src', 'data-url', 'data-video']
                });
                sendLog('MutationObserver started');
            }
            
            function checkIframes() {
                document.querySelectorAll('iframe').forEach(iframe => {
                    try {
                        if (iframe.contentDocument) {
                            iframe.contentDocument.querySelectorAll('video').forEach(processVideoElement);
                            iframe.contentDocument.querySelectorAll('audio').forEach(processAudioElement);
                        }
                    } catch(e) {}
                });
            }
            
            setInterval(checkIframes, 2000);
        })();
        """#
        
        // Script 3: Iframe Injector (for recursive iframe injection)
        let iframeInjectorScript = #"""
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
                if (!url || url.includes('googleads')) return;
                sendToNative(url, 'VideoBridge');
            }
            
            function isVideoURL(url) {
                if (!url) return false;
                const videoExtensions = ['.m3u8', '.mp4', '.webm', '.mkv', '.ts', '.flv', '.mov', '.mpd'];
                const lowerUrl = url.toLowerCase();
                return videoExtensions.some(ext => lowerUrl.includes(ext)) ||
                       lowerUrl.includes('video') ||
                       lowerUrl.includes('stream') ||
                       lowerUrl.includes('playback') ||
                       lowerUrl.includes('play') ||
                       lowerUrl.includes('hls') ||
                       lowerUrl.includes('dash');
            }
            
            function injectNetworkInterceptors(win) {
                if (win.__kazumiNetworkInjected) return;
                win.__kazumiNetworkInjected = true;
                
                const originalFetch = win.fetch;
                win.fetch = function(...args) {
                    const url = args[0];
                    if (typeof url === 'string' && isVideoURL(url)) {
                        sendLog('Iframe fetch detected: ' + url);
                        sendVideo(url);
                    }
                    return originalFetch.apply(this, args);
                };
                
                const originalXHROpen = win.XMLHttpRequest.prototype.open;
                win.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                    if (typeof url === 'string' && isVideoURL(url)) {
                        sendLog('Iframe XHR detected: ' + url);
                        sendVideo(url);
                    }
                    return originalXHROpen.call(this, method, url, ...rest);
                };
                
                try {
                    const OriginalWebSocket = win.WebSocket;
                    win.WebSocket = function(url, protocols) {
                        const ws = new OriginalWebSocket(url, protocols);
                        ws.addEventListener('message', function(event) {
                            const data = event.data;
                            if (typeof data === 'string') {
                                const matches = data.match(/(https?:\/\/[^\s"'<>]+\.(?:m3u8|mp4|webm|ts|flv|mov|mkv|mpd))/gi);
                                if (matches) matches.forEach(match => sendVideo(match));
                            }
                        });
                        return ws;
                    };
                    win.WebSocket.prototype = OriginalWebSocket.prototype;
                } catch(e) {}
                
                try {
                    const originalSrcSetter = Object.getOwnPropertyDescriptor(win.HTMLMediaElement.prototype, 'src')?.set;
                    if (originalSrcSetter) {
                        Object.defineProperty(win.HTMLMediaElement.prototype, 'src', {
                            set: function(value) {
                                if (isVideoURL(value) || value.startsWith('blob:')) {
                                    sendVideo(value);
                                }
                                return originalSrcSetter.call(this, value);
                            },
                            get: function() {
                                return this.getAttribute('src');
                            }
                        });
                    }
                } catch(e) {}
            }
            
            function injectIntoIframe(iframe) {
                if (iframe.__kazumiInjected) return;
                iframe.__kazumiInjected = true;
                
                try {
                    const iframeWindow = iframe.contentWindow;
                    const iframeDoc = iframe.contentDocument;
                    
                    if (!iframeWindow || !iframeDoc) {
                        sendLog('Cannot access iframe content (cross-origin)');
                        return;
                    }
                    
                    sendLog('Injecting into iframe: ' + iframe.src);
                    injectNetworkInterceptors(iframeWindow);
                    
                    iframeDoc.querySelectorAll('video').forEach(video => {
                        const src = video.getAttribute('src') || video.currentSrc;
                        if (src) {
                            sendLog('Iframe video found: ' + src);
                            sendVideo(src);
                        }
                    });
                    
                    iframeDoc.querySelectorAll('audio').forEach(audio => {
                        const src = audio.getAttribute('src') || audio.currentSrc;
                        if (src) {
                            sendLog('Iframe audio found: ' + src);
                            sendVideo(src);
                        }
                    });
                    
                    iframeDoc.querySelectorAll('iframe').forEach(injectIntoIframe);
                    
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
                    sendLog('Iframe injection error: ' + e.message);
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
                            sendLog('New iframe detected: ' + node.src);
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
            
            sendLog('Iframe injector loaded');
        })();
        """#
        
        // Script 4: Legacy iframe & embed scanner
        let legacyIframeScript = #"""
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
            
            sendLog('Legacy iframe scanner loaded');
            
            const iframes = document.getElementsByTagName('iframe');
            sendLog('Found ' + iframes.length + ' iframes');
            
            for (let i = 0; i < iframes.length; i++) {
                const iframe = iframes[i];
                const src = iframe.getAttribute('src') || iframe.getAttribute('data-src');
                if (src && src.trim() !== '') {
                    sendLog('Iframe ' + i + ' src: ' + src);
                    if (src.includes('http') && !src.includes('googleads')) {
                        sendVideo(src);
                    }
                }
            }
            
            // Scan embed and object tags
            document.querySelectorAll('embed[src], object[data]').forEach(el => {
                const url = el.getAttribute('src') || el.getAttribute('data');
                if (url && url.includes('http') && !url.includes('googleads')) {
                    sendLog('Embed/Object found: ' + url);
                    sendVideo(url);
                }
            });
        })();
        """#
        
        // Script 5: Performance fallback scanner
        let performanceFallbackScript = #"""
        (function() {
            'use strict';
            
            function sendToNative(message, handler) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
                    window.webkit.messageHandlers[handler].postMessage(message);
                }
            }
            
            function sendVideo(url) {
                if (!url || url.includes('googleads')) return;
                sendToNative(url, 'VideoBridge');
            }
            
            function isVideoURL(url) {
                if (!url) return false;
                const videoExtensions = ['.m3u8', '.mp4', '.webm', '.mkv', '.ts', '.flv', '.mov', '.mpd'];
                const lowerUrl = url.toLowerCase();
                return videoExtensions.some(ext => lowerUrl.includes(ext)) ||
                       lowerUrl.includes('video') ||
                       lowerUrl.includes('stream') ||
                       lowerUrl.includes('playback') ||
                       lowerUrl.includes('play') ||
                       lowerUrl.includes('hls') ||
                       lowerUrl.includes('dash');
            }
            
            function scanPerformanceEntries() {
                if (!window.performance || !window.performance.getEntriesByType) return;
                const entries = window.performance.getEntriesByType('resource');
                entries.forEach(entry => {
                    if (isVideoURL(entry.name)) {
                        sendVideo(entry.name);
                    }
                });
            }
            
            // Scan after page load and periodically
            if (document.readyState === 'complete') {
                setTimeout(scanPerformanceEntries, 1500);
            } else {
                window.addEventListener('load', () => {
                    setTimeout(scanPerformanceEntries, 1500);
                });
            }
            
            setInterval(scanPerformanceEntries, 3000);
        })();
        """#
        
        // Add all user scripts
        let scripts: [(String, WKUserScriptInjectionTime)] = [
            (networkInterceptorScript, .atDocumentStart),
            (videoScannerScript, .atDocumentEnd),
            (iframeInjectorScript, .atDocumentEnd),
            (legacyIframeScript, .atDocumentEnd),
            (performanceFallbackScript, .atDocumentEnd)
        ]
        
        for script in scripts {
            let userScript = WKUserScript(
                source: script.0,
                injectionTime: script.1,
                forMainFrameOnly: false
            )
            webView.configuration.userContentController.addUserScript(userScript)
        }
        
        addLog("所有脚本已注入 (\(scripts.count) 个)")
    }
}

// MARK: - JavaScript Message Handling

extension AnimeVideoExtractor: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
        // Avoid duplicates
        guard !detectedSources.contains(urlString) else { return }
        detectedSources.insert(urlString)
        
        addLog("✅ 发现视频源: \(urlString.prefix(60))...")
        
        // Check if it's a valid video URL (relaxed matching)
        let lowercased = urlString.lowercased()
        let isM3U8 = lowercased.contains(".m3u8") || lowercased.contains("application/vnd.apple.mpegurl")
        let isMP4 = lowercased.contains(".mp4") || lowercased.contains("video/mp4")
        let isTS = lowercased.contains(".ts") || lowercased.contains("video/MP2T")
        let isFLV = lowercased.contains(".flv")
        let isWebM = lowercased.contains(".webm")
        let isMKV = lowercased.contains(".mkv")
        let isMPD = lowercased.contains(".mpd") || lowercased.contains("application/dash+xml")
        let isHLS = lowercased.contains("/hls/") || lowercased.contains("format=m3u8") || lowercased.contains("type=m3u8")
        let isStream = lowercased.contains("stream") || lowercased.contains("playback") || lowercased.contains("play") || lowercased.contains("video")
        let isEmbedPlayer = lowercased.contains("player") || lowercased.contains("embed") || lowercased.contains("iframe")
        
        guard isM3U8 || isMP4 || isTS || isFLV || isWebM || isMKV || isMPD || isHLS || isStream || isEmbedPlayer || lowercased.hasPrefix("blob:") else {
            addLog("⚠️ URL 格式不符合视频特征，继续等待")
            return
        }
        
        // Determine quality label and type
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
        } else if lowercased.hasPrefix("blob:") {
            quality = "Blob"
            type = "blob"
        } else if isEmbedPlayer {
            quality = "Embed"
            type = "embed"
        }
        
        // Create VideoSource
        let source = VideoSource(
            quality: quality,
            url: urlString,
            type: type,
            label: nil
        )
        
        // For now, take the first valid source found
        isVideoFound = true
        progressMessage = "找到视频源: \(quality)"
        
        // Small delay to potentially find better quality sources
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if !self.isVideoFound { return }
            
            let sources = [source]
            self.finish(with: .success(sources), resolveId: self.resolveId)
        }
    }
}

// MARK: - Navigation Delegate

extension AnimeVideoExtractor: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            self.progressMessage = "正在加载页面..."
            self.addLog("页面开始加载")
        }
    }
    
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.progressMessage = "页面加载完成，扫描视频..."
            self.addLog("✅ 页面加载完成")
            
            // Inject additional scripts after page load
            self.injectPostLoadScripts()
            
            // Set a fallback timeout for video detection
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                if !self.isVideoFound && self.continuation != nil {
                    self.addLog("⚠️ 5秒内未检测到视频，继续等待...")
                }
            }
        }
    }
    
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.addLog("❌ 页面加载失败: \(error.localizedDescription)")
            if !self.isVideoFound {
                self.finish(with: .error("页面加载失败: \(error.localizedDescription)"), resolveId: self.resolveId)
            }
        }
    }
    
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.addLog("❌ 页面加载失败: \(error.localizedDescription)")
            if !self.isVideoFound {
                self.finish(with: .error("页面加载失败: \(error.localizedDescription)"), resolveId: self.resolveId)
            }
        }
    }
    
    // Handle captcha detection
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // 同步检查 URL
        let isCaptcha: Bool
        if let url = navigationResponse.response.url?.absoluteString {
            let captchaIndicators = ["captcha", "verify", "challenge", "recaptcha", "hcaptcha"]
            isCaptcha = captchaIndicators.contains(where: { url.lowercased().contains($0) })
        } else {
            isCaptcha = false
        }
        
        if isCaptcha {
            // 立即调用 decisionHandler
            decisionHandler(.cancel)
            // 异步执行其他操作
            Task { @MainActor in
                self.addLog("⚠️ 检测到验证码页面")
                self.finish(with: .captcha, resolveId: self.resolveId)
            }
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - Post-Load Scripts

private extension AnimeVideoExtractor {
    func injectPostLoadScripts() {
        // Script to force play hidden videos (some sites hide the player initially)
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
        
        // Script to remove common anti-debugger checks
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
    
    func handleTimeout(resolveId: Int) {
        guard resolveId == self.resolveId else { return }
        
        if isVideoFound {
            // Already found video, ignore timeout
            return
        }
        
        addLog("❌ 解析超时")
        finish(with: .timeout, resolveId: resolveId)
    }
    
    func finish(with result: VideoExtractionResult, resolveId: Int) {
        guard resolveId == self.resolveId else { return }
        
        timeoutTask?.cancel()
        timeoutTask = nil
        
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
        
        // Clean up WebView
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        
        // Resume continuation
        continuation?.resume(returning: result)
        continuation = nil
    }
}
