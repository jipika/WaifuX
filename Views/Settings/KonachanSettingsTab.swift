import SwiftUI
import WebKit

/// Konachan 设置标签：账号登录与 Cloudflare 人机验证。
struct KonachanSettingsTab: View {
    @ObservedObject private var authService = KonachanAuthService.shared
    @State private var showLoginSheet = false

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: "账号与访问验证") {
                MacSettingsRow(
                    title: authService.statusTitle,
                    subtitle: authService.statusSubtitle,
                    showDivider: authService.hasUsableSession
                ) {
                    Button(authService.hasUsableSession ? "重新登录 / 验证" : "登录 / 验证") {
                        showLoginSheet = true
                    }
                    .controlSize(.small)
                }

                if authService.hasUsableSession {
                    MacSettingsRow(
                        title: "清除 Konachan 会话",
                        subtitle: "移除本机保存的登录和 Cloudflare Cookie。",
                        showDivider: false
                    ) {
                        Button("清除") {
                            Task {
                                await authService.logout()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Text("登录页使用与应用请求相同的浏览器标识。完成 Cloudflare 检查或账号登录后，Cookie 仅保存在本机并自动供 Konachan API、缩略图和原图下载使用。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, -12)
                .padding(.leading, 2)
        }
        .sheet(isPresented: $showLoginSheet, onDismiss: {
            Task {
                await authService.saveWebSession()
            }
        }) {
            KonachanLoginSheet(authService: authService)
        }
        .task {
            await authService.checkLoginState()
        }
    }
}

private struct KonachanLoginSheet: View {
    @ObservedObject var authService: KonachanAuthService
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Konachan 登录与验证")
                        .font(.headline)
                    Text("可登录账号，也可只完成 Cloudflare 人机验证。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            KonachanLoginWebView(authService: authService)
                .frame(minWidth: 840, minHeight: 600)

            Divider()

            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.green)
                Text("完成页面上的登录或验证后，点击“完成并保存”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("完成并保存") {
                    Task {
                        isSaving = true
                        await authService.saveWebSession()
                        isSaving = false
                        dismiss()
                    }
                }
                .disabled(isSaving)
                .controlSize(.regular)
            }
            .padding()
        }
        .frame(minWidth: 840, minHeight: 720)
    }
}

private struct KonachanLoginWebView: NSViewRepresentable {
    @ObservedObject var authService: KonachanAuthService

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = KonachanRequestConfiguration.browserUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: KonachanRequestConfiguration.loginURL))
        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator _: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(authService: authService)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let authService: KonachanAuthService

        init(authService: KonachanAuthService) {
            self.authService = authService
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            Task { @MainActor in
                await authService.saveWebSession()
            }
        }
    }
}
