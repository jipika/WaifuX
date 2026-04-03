import SwiftUI

// MARK: - 验证码 / 人机验证（应用内 WebView）

struct CaptchaVerificationSheet: View {
    let startURL: URL
    let ruleName: String
    var customUserAgent: String?
    let onCancel: () -> Void
    let onVerified: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("验证 — \(ruleName)")
                    .font(.headline)
                Spacer()
                Button("关闭", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Text("在页面中完成验证（滑块、点击等）后，点击下方按钮同步会话并继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)

            CaptchaVerificationWebView(url: startURL, customUserAgent: customUserAgent)
                .frame(minWidth: 560, minHeight: 420)

            Divider()

            HStack {
                Button("取消", action: onCancel)
                Spacer()
                Button("验证完成，继续") {
                    onVerified()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 580, minHeight: 520)
    }
}
