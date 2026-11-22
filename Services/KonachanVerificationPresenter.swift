import AppKit
import SwiftUI

// MARK: - Konachan Cloudflare 人机验证弹窗
///
/// 探索页请求被 Cloudflare 拦截时，用户需要先在一个真实浏览器环境里通过挑战，
/// `cf_clearance` Cookie 才会签发。设置页里的登录表单藏在两层导航之后，从报错到
/// 完成验证的路径太长；这里提供一个随处可调用的独立窗口：
///   - 加载与 API 相同的 `.com` 域名接口页，触发与失败请求同一套 WAF 规则；
///   - 打开前清掉旧 `cf_clearance`，避免用过期 Cookie 误判「已验证」；
///   - 轮询 WebView Cookie 存储，拿到新 Cookie 后同步到 `HTTPCookieStorage.shared`，
///     自动关窗并回调重试原请求。
@MainActor
final class KonachanVerificationPresenter {
    static let shared = KonachanVerificationPresenter()

    enum Trigger {
        /// 用户主动点击「人机验证」
        case manual
        /// 请求被拦截后自动弹出（每个进程只自动弹一次，避免反复打断）
        case intercepted

        var isAutomatic: Bool {
            if case .intercepted = self { return true }
            return false
        }
    }

    private var windowController: KonachanVerificationWindowController?
    private var hasAutoPresented = false

    private init() {}

    var isPresenting: Bool {
        windowController?.window?.isVisible == true
    }

    /// 打开或聚焦验证弹窗。
    /// - Parameters:
    ///   - trigger: 触发来源；自动触发在每个进程内只生效一次。
    ///   - onVerified: 挑战通过、会话已写入共享 Cookie 存储后的回调（用于重试原请求）。
    func present(trigger: Trigger = .manual, onVerified: (() -> Void)? = nil) {
        if let controller = windowController,
           let window = controller.window,
           window.isVisible {
            controller.addCompletion(onVerified)
            WindowSpaceCoordinator.show(window)
            return
        }

        if trigger.isAutomatic {
            guard !hasAutoPresented else { return }
            hasAutoPresented = true
        }

        let controller = KonachanVerificationWindowController(
            onVerified: onVerified,
            onClose: { [weak self] in
                self?.windowController = nil
            }
        )
        windowController = controller
        if let window = controller.window {
            WindowSpaceCoordinator.show(window)
        }
    }
}

// MARK: - 弹窗控制器

@MainActor
final class KonachanVerificationWindowController: NSWindowController, NSWindowDelegate {
    private var completions: [() -> Void] = []
    private let onClose: () -> Void
    private var didComplete = false

    init(onVerified: (() -> Void)?, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let onVerified {
            completions.append(onVerified)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = t("Konachan 人机验证")
        window.minSize = NSSize(width: 760, height: 540)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)
        window.delegate = self

        let content = KonachanVerificationView(
            onVerified: { [weak self] in self?.handleVerified() },
            onCancel: { [weak self] in self?.close() }
        )
        let hostingView = NSHostingView(rootView: content)
        // #130/#132：内容含 WKWebView 平台视图，禁止 SwiftUI 内容反推窗口尺寸，
        // 避免约束更新循环。窗口尺寸由 NSWindow 管理（minSize 已设）。
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 700)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addCompletion(_ completion: (() -> Void)?) {
        guard let completion else { return }
        completions.append(completion)
    }

    /// 挑战通过：先让成功状态停留片刻再关窗，并把所有等待中的重试回调一次性放行。
    private func handleVerified() {
        guard !didComplete else { return }
        didComplete = true

        let pending = completions
        completions = []

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.close()
            pending.forEach { $0() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
