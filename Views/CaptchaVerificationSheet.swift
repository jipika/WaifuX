import SwiftUI

// MARK: - 验证码 / 人机验证（应用内 WebView）
// 采用流媒体专业风格设计

struct CaptchaVerificationSheet: View {
    let startURL: URL
    let ruleName: String
    var customUserAgent: String?
    let onCancel: () -> Void
    let onVerified: () -> Void
    
    @State private var isCancelHovered = false
    @State private var isVerifyHovered = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 深色专业背景
                Color(hex: "0D0D10")
                    .ignoresSafeArea()
                
                // 顶部渐变光效
                VStack {
                    LinearGradient(
                        colors: [
                            Color(hex: "8B5CF6").opacity(0.12),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 180)
                    
                    Spacer()
                }
                .ignoresSafeArea()

                // 主内容区
                VStack(spacing: 0) {
                    // 专业标题栏
                    header
                    
                    // 信息提示区
                    infoBanner
                    
                    // WebView 容器
                    webviewContainer(in: geometry)
                    
                    // 底部操作栏
                    footer
                }
            }
        }
        .frame(minWidth: 920, minHeight: 720)
    }
    
    // MARK: - 标题栏
    private var header: some View {
        HStack(spacing: 16) {
            // 左侧图标和标题
            HStack(spacing: 12) {
                // 验证图标
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: "FF9F43").opacity(0.3),
                                    Color(hex: "FF9F43").opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(hex: "FF9F43"))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(t("captcha.verification"))")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    
                    Text(ruleName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            // 关闭按钮
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isCancelHovered ? .white : .white.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(isCancelHovered ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isCancelHovered = hovering
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
    
    // MARK: - 信息横幅
    private var infoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "00D4FF"))
            
            Text(t("captcha.completeInstructions"))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: "00D4FF").opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(hex: "00D4FF").opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
    
    // MARK: - WebView 容器
    private func webviewContainer(in geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // WebView 标题栏
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                    
                    Text(startURL.host ?? t("captcha.verificationPage"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                
                Spacer()
                
                // 安全指示器
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: "34D399"))
                        .frame(width: 6, height: 6)
                    
                    Text(t("captcha.secureConnection"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: "34D399"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color(hex: "34D399").opacity(0.15))
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Rectangle()
                    .fill(Color(hex: "1A1A20"))
            )
            
            Divider()
                .background(Color.white.opacity(0.08))
            
            // WebView
            CaptchaVerificationWebView(url: startURL, customUserAgent: customUserAgent)
                .frame(minHeight: 500)
            
            Divider()
                .background(Color.white.opacity(0.08))
            
            // 底部工具栏
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    
                    Text("HTTPS")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                
                Spacer()
                
                Text(t("captcha.privacyProtected"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(hex: "1A1A20"))
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: "121216"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.4), radius: 24, y: 12)
        .padding(.horizontal, 24)
    }
    
    // MARK: - 底部操作栏
    private var footer: some View {
        HStack(spacing: 16) {
            // 取消按钮
            Button {
                onCancel()
            } label: {
                Text(t("cancel"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 120, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer()
            
            // 帮助文字
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                Text(t("captcha.needHelp"))
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white.opacity(0.4))

            Spacer()

            // 完成验证按钮
            Button {
                onVerified()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(t("captcha.verificationComplete"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 180, height: 42)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        isVerifyHovered ? Color(hex: "22C55E") : Color(hex: "34D399"),
                                        isVerifyHovered ? Color(hex: "16A34A") : Color(hex: "10B981")
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        
                        // 顶部高光
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.25),
                                        Color.white.opacity(0.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .padding(.top, 1)
                            .padding(.horizontal, 1)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .shadow(
                    color: Color(hex: "34D399").opacity(isVerifyHovered ? 0.5 : 0.3),
                    radius: isVerifyHovered ? 16 : 10,
                    y: isVerifyHovered ? 6 : 3
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.2)) {
                    isVerifyHovered = hovering
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

// MARK: - 预览
#Preview {
    CaptchaVerificationSheet(
        startURL: URL(string: "https://example.com/captcha")!,
        ruleName: "测试规则",
        onCancel: {},
        onVerified: {}
    )
}
