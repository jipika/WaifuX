import SwiftUI

/// Pixiv 设置标签：账号管理
///
/// 显示当前登录状态，支持登录 / 登出操作。
/// 登录弹窗复用 `PixivLoginSheet`。
struct PixivSettingsTab: View {
    @ObservedObject private var authService = PixivAuthService.shared
    @State private var showLoginSheet = false

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: "账号") {
                if authService.isLoggedIn {
                    loggedInRow
                } else {
                    loggedOutRow
                }
            }

            Text("Cookie 仅存储在本地，不会上传。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, -12)
                .padding(.leading, 2)
        }
        .sheet(isPresented: $showLoginSheet) {
            PixivLoginSheet(authService: authService)
        }
        .task {
            // 每次打开设置页时检查登录状态（从 WKWebView cookie 恢复）
            await authService.checkLoginState()
        }
    }

    // MARK: - 已登录

    private var loggedInRow: some View {
        MacSettingsRow(
            title: authService.pixivUserName ?? "Pixiv 用户",
            subtitle: authService.pixivUserID.map { "uid: \($0)" },
            showDivider: false
        ) {
            Button("退出登录") {
                Task {
                    await authService.logout()
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - 未登录

    private var loggedOutRow: some View {
        MacSettingsRow(
            title: "登录 Pixiv 账号以浏览更多内容",
            subtitle: "",
            showDivider: false
        ) {
            Button("登录 Pixiv") {
                showLoginSheet = true
            }
            .controlSize(.small)
        }
    }
}
