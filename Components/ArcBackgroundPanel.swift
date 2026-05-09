import SwiftUI
import AppKit

// MARK: - Arc 背景控制面板按钮（与重置按钮相同样式）

struct ArcBackgroundPanelButton: View {
    @State private var isPanelOpen = false
    let tint: Color
    @Binding var grainIntensity: Double
    let onRandomize: () -> Void

    @Environment(\.arcIsLightMode) private var isLightMode
    private var txt: ArcTextColors { ArcTextColors(isLightMode: isLightMode) }
    @State private var isHovered = false

    var body: some View {
        Button {
            isPanelOpen.toggle()
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(txt.primary.opacity(0.92))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .arcFrostedCircle(
                    intensity: ArcBackgroundSettings.shared.frostedIntensity,
                    isLightMode: isLightMode,
                    accentColor: tint
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPanelOpen, arrowEdge: .bottom) {
            ArcBackgroundPanel(
                isPresented: $isPanelOpen,
                grainIntensity: $grainIntensity,
                onRandomize: onRandomize
            )
        }
    }
}

// MARK: - Arc 背景控制面板

struct ArcBackgroundPanel: View {
    @Binding var isPresented: Bool
    @Binding var grainIntensity: Double
    let onRandomize: () -> Void
    @ObservedObject private var settings = ArcBackgroundSettings.shared
    
    /// 弹窗配色固定跟随 macOS 系统强调色，不再跟随页面或自定义随机色变化。
    private var systemAccentColor: Color {
        Color(nsColor: .controlAccentColor)
    }

    var body: some View {
        VStack(spacing: 20) {
            // 1. 模式切换（Auto / Light / Dark）
            modeSwitcher

            // 2. 背景预览 + 颗粒度强度
            previewSection

            // 3. 随机按钮
            randomButton
        }
        .padding(24)
        .frame(width: 320)
        .arcFrostedGlass(
            cornerRadius: 24,
            intensity: settings.frostedIntensity,
            isLightMode: settings.isLightMode,
            accentColor: systemAccentColor,
            useNoise: false
        )
    }

    // MARK: - 模式切换

    private var modeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(ArcThemeMode.allCases) { mode in
                let isSelected = settings.themeMode == mode

                Button {
                    settings.setThemeMode(mode)
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? settings.primaryText : settings.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isSelected ? systemAccentColor.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(settings.isLightMode ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
        )
    }

    // MARK: - 预览区 + 颗粒度

    private var previewSection: some View {
        VStack(spacing: 12) {
            // 背景预览
            ZStack {
                ArcAtmosphereBackground(
                    tint: ExploreAtmosphereTint.fromSampledTriplet(systemAccentColor, systemAccentColor.opacity(0.7), systemAccentColor.opacity(0.5)),
                    referenceImage: nil,
                    isLightMode: settings.isLightMode,
                    dotGridOpacity: settings.dotGridOpacity,
                    useNoise: true,
                    grainIntensity: grainIntensity
                )
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(settings.borderColor, lineWidth: 0.5)
                )

                // 示例内容
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(systemAccentColor.opacity(0.3))
                            .frame(width: 40, height: 20)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(settings.secondaryText.opacity(0.2))
                            .frame(width: 80, height: 20)
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(settings.secondaryText.opacity(0.15))
                        .frame(width: 160, height: 12)
                }
            }

            // 颗粒度滑块
            HStack(spacing: 8) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(settings.secondaryText)

                Slider(value: $grainIntensity, in: 0.0...1.0)
                    .tint(systemAccentColor)
                    .frame(height: 20)

                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(settings.secondaryText)
            }
        }
    }

    // MARK: - 随机按钮

    private var randomButton: some View {
        Button {
            onRandomize()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "dice")
                    .font(.system(size: 13, weight: .semibold))
                Text("随机背景")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(settings.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(systemAccentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(systemAccentColor.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
