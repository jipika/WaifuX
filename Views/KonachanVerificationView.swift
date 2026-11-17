import SwiftUI
import WebKit

// MARK: - Konachan 人机验证弹窗内容
///
/// 页面加载失败/被挑战时都在同一个 WKWebView 里完成：Cloudflare 的 Turnstile
/// 勾选框会直接渲染在页面中央，用户点一下即可签发 `cf_clearance`。

struct KonachanVerificationView: View {
    var onVerified: () -> Void
    var onCancel: () -> Void

    @StateObject private var probe = KonachanChallengeProbe()
    @State private var didScheduleCompletion = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                KonachanChallengeWebView(probe: probe)
                successOverlay
            }
            .frame(minWidth: 720, minHeight: 400)
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: probe.phase) { _, phase in
            switch phase {
            case .verified, .notChallenged:
                scheduleCompletion()
            case .preparing, .waiting, .rejected, .failed:
                break
            }
        }
        .onDisappear {
            probe.stop()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(t("Konachan 人机验证"))
                    .font(.system(size: 15, weight: .semibold))
                Text(t("完成 Cloudflare 挑战后会自动保存会话并继续加载。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                if probe.phase == .preparing || probe.phase == .waiting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Text(statusText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(statusTint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(statusTint.opacity(0.12))
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 成功覆盖层

    @ViewBuilder
    private var successOverlay: some View {
        switch probe.phase {
        case .verified:
            overlayPanel(
                icon: "checkmark.shield.fill",
                tint: .green,
                title: t("验证成功，正在继续加载…")
            )
        case .notChallenged:
            overlayPanel(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: t("当前网络没有被挑战，可以直接重试。")
            )
        default:
            EmptyView()
        }
    }

    private func overlayPanel(icon: String, tint: Color, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
        .transition(.opacity)
    }

    // MARK: - 底部操作栏

    private var footer: some View {
        HStack(spacing: 12) {
            if case .rejected = probe.phase {
                Text(t("该出口被 Cloudflare 直接拒绝，请更换节点后重试。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            } else if case .failed = probe.phase {
                Text(t("页面加载失败，请点「重新加载挑战页」。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
            } else if probe.showsManualHint {
                Text(t("尚未检测到验证 Cookie，请先在页面完成挑战。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text(t("挑战通过后 Cookie 仅保存在本机，并自动供 Konachan 接口、缩略图与原图使用。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(t("重新加载挑战页")) {
                probe.reload()
            }
            .controlSize(.small)
            .disabled(probe.phase == .preparing || probe.phase == .verified)

            Button(t("我已完成验证")) {
                Task { await probe.completeManually() }
            }
            .controlSize(.small)
            .disabled(probe.phase == .verified)

            Button(t("cancel")) {
                onCancel()
            }
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 状态映射

    private var statusText: String {
        switch probe.phase {
        case .preparing:
            return t("正在准备挑战页…")
        case .waiting:
            return t("正在等待 Cloudflare 挑战…")
        case .verified:
            return t("验证成功，正在继续加载…")
        case .notChallenged:
            return t("当前网络没有被挑战，可以直接重试。")
        case .rejected:
            return t("该出口被 Cloudflare 直接拒绝，请更换节点后重试。")
        case .failed:
            return t("页面加载失败，请点「重新加载挑战页」。")
        }
    }

    private var statusIcon: String {
        switch probe.phase {
        case .preparing, .waiting:
            return "shield.lefthalf.filled"
        case .verified, .notChallenged:
            return "checkmark.shield.fill"
        case .rejected, .failed:
            return "exclamationmark.shield.fill"
        }
    }

    private var statusTint: Color {
        switch probe.phase {
        case .preparing, .waiting:
            return .orange
        case .verified, .notChallenged:
            return .green
        case .rejected, .failed:
            return .red
        }
    }

    private func scheduleCompletion() {
        guard !didScheduleCompletion else { return }
        didScheduleCompletion = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            onVerified()
        }
    }
}

// MARK: - WKWebView 桥接

private struct KonachanChallengeWebView: NSViewRepresentable {
    @ObservedObject var probe: KonachanChallengeProbe

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = KonachanRequestConfiguration.browserUserAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = probe

        probe.attach(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Void) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.loadHTMLString("", baseURL: nil)
    }
}

// MARK: - 挑战状态机

@MainActor
final class KonachanChallengeProbe: NSObject, ObservableObject {
    enum Phase: Equatable {
        case preparing
        case waiting
        case verified
        case notChallenged
        case rejected
        case failed
    }

    @Published private(set) var phase: Phase = .preparing
    /// 用户点了「我已完成验证」但 Cookie 还没出现
    @Published private(set) var showsManualHint = false

    private weak var webView: WKWebView?
    private var pollTask: Task<Void, Never>?
    private var didStart = false
    private var generation = 0

    func attach(_ webView: WKWebView) {
        self.webView = webView
        guard !didStart else { return }
        didStart = true
        beginChallenge()
    }

    /// 重新走一遍：清掉旧 Cookie → 加载挑战页 → 轮询新 Cookie。
    func reload() {
        beginChallenge()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 用户手动确认：先同步 Cookie；没有 `cf_clearance` 就继续等待。
    func completeManually() async {
        await KonachanAuthService.shared.saveWebSession()
        if KonachanAuthService.shared.hasCloudflareClearance {
            finishVerified()
        } else {
            showsManualHint = true
        }
    }

    private func beginChallenge() {
        generation += 1
        let generation = generation
        pollTask?.cancel()
        showsManualHint = false
        phase = .preparing

        Task { [weak self] in
            await KonachanAuthService.shared.clearCloudflareClearance()
            guard let self, self.generation == generation else { return }
            self.loadChallengePage()
            self.startPolling(generation: generation)
        }
    }

    private func loadChallengePage() {
        guard let webView else { return }

        var request = URLRequest(url: KonachanRequestConfiguration.verificationURL)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7,ja;q=0.6",
            forHTTPHeaderField: "Accept-Language"
        )

        webView.load(request)
        phase = .waiting
    }

    private func startPolling(generation: Int) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self, self.generation == generation else { return }
                if self.phase == .verified { return }

                if await KonachanAuthService.shared.adoptClearanceCookieFromWebStore() {
                    self.finishVerified()
                    return
                }
            }
        }
    }

    private func finishVerified() {
        guard phase != .verified else { return }
        phase = .verified
        showsManualHint = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func handle(response: HTTPURLResponse) {
        guard phase != .verified else { return }

        let mimeType = (response.mimeType ?? "").lowercased()
        let isJSON = mimeType.contains("json")

        if (200..<300).contains(response.statusCode), isJSON {
            // 接口页直接返回了 JSON：这个出口没有被挑战，Cookie 同步后重试即可。
            phase = .notChallenged
        } else if response.statusCode == 403 || response.statusCode == 503, isJSON {
            // 非交互式拒绝：挑战页不会出现，只能换出口。
            phase = .rejected
        }
    }
}

// MARK: - WKNavigationDelegate

extension KonachanChallengeProbe: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse {
            handle(response: response)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard phase != .verified else { return }
        phase = .failed
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        guard phase != .verified, phase != .notChallenged else { return }
        phase = .failed
    }
}
