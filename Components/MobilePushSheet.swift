import SwiftUI
import AppKit

/// 「推送到手机」弹窗 — 与 DisplaySelectorSheet 同套液态玻璃视觉。
/// 流程：起服务端 → 展示配对码(大号液态玻璃数字) → 手机输码 → 自动推送 → 完成态。
struct MobilePushSheet: View {
    let title: String
    /// 手动取消（关弹窗同时杀服务端）
    let onCancel: () -> Void

    @ObservedObject private var push = MobilePushService.shared
    @State private var isVisible = false
    @State private var copied = false

    private var phase: MobilePushService.PushPhase { push.phase }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                // 推送期间误点空白不能关掉服务端；只允许底部按钮显式关闭。

            VStack(spacing: 18) {
                switch phase {
                case .idle, .converting:
                    convertingView
                case .waitingPairing(let pin):
                    pairingView(pin: pin)
                case .pushing(let name, let progress):
                    pushingView(name: name, progress: progress)
                case .done:
                    doneView
                case .failed(let message):
                    failedView(message)
                }

                // 底部取消/关闭
                Button {
                    dismiss()
                } label: {
                    Text(phase == .done ? t("done") : t("cancel"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .liquidGlassSurface(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .liquidGlassSurface(
                .prominent,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .scaleEffect(isVisible ? 1.0 : 0.88)
            .opacity(isVisible ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isVisible = true
                }
            }
        }
        // Esc 与空白点击一样不关闭，避免配对/传输被意外中断。
    }

    // MARK: - 阶段视图

    private var convertingView: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.and.arrow.down")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(t("准备推送到手机"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            Text("正在转换「\(title)」为手机格式…")
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .multilineTextAlignment(.center)
            ProgressView()
                .controlSize(.regular)
        }
        .padding(.vertical, 8)
    }

    private func pairingView(pin: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(t("等待手机连接"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            Text("已配对过：在 Wallpaper Engine 里选择「\(LocalizedBrand.name)」即可自动连接。\n新设备：选择电脑后输入下方配对码。")
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .multilineTextAlignment(.center)

            // 配对码大字
            HStack(spacing: 8) {
                ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 60)
                        .liquidGlassSurface(
                            .max,
                            tint: Color.accentColor.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
            }
            .padding(.vertical, 4)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pin, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? t("已复制") : t("复制配对码"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
                    .liquidGlassSurface(.regular, in: Capsule())
            }
            .buttonStyle(.plain)

            Text(t("若传输中断，请保持此页面；重新选择电脑后会自动重传"))
                .font(.system(size: 11))
                .foregroundStyle(LiquidGlassColors.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private func pushingView(name: String, progress: Double) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(t("正在推送到手机"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .frame(maxWidth: 240)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(LiquidGlassColors.textSecondary)
        }
        .padding(.vertical, 8)
    }

    private var doneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color(hex: "30D158"))
            Text(t("推送完成"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            Text(t("手机 Wallpaper Engine 列表里已出现新壁纸"))
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color(hex: "FF9F0A"))
            Text(t("推送未完成"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private func dismiss() {
        push.stopPush()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            onCancel()
        }
    }
}

/// 品牌名（避免硬编码散落）
private enum LocalizedBrand {
    static let name = "WaifuX"
}
