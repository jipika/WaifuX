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
                Text("\(t("captcha.verification")) — \(ruleName)")
                    .font(.headline)
                Spacer()
                Button(t("captcha.close"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            Text(t("captcha.completeInstructions"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)

            CaptchaVerificationWebView(url: startURL, customUserAgent: customUserAgent)
                .frame(minWidth: 860, minHeight: 600)

            Divider()

            HStack {
                Button(t("cancel"), action: onCancel)
                Spacer()
                Button(t("captcha.verificationComplete")) {
                    onVerified()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 900, minHeight: 720)
    }
}
