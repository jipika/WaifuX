import SwiftUI
import Combine
import MetalKit

// MARK: - 液态玻璃时钟视图
//
// 桌面壁纸层上的原生 Metal 时钟叠加组件。
// 使用 Liquid Glass 设计系统呈现毛玻璃质感的时钟/日期信息。
//
// ═══════════════════════════════════════════════════════════
// 渲染架构（双路径）：
//
// 路径 A — Metal 着色器（metalShaderEnabled = true）
//   ┌─────────────────────────────────────┐
//   │  LiquidGlassMetalClockView (MTKView) │  ← Metal 渲染玻璃背景
//   │  ┌─────────────────────────────────┐ │
//   │  │  SwiftUI Text 叠加层            │ │  ← 文字由 Core Text 渲染
//   │  │  时间/日期/星期                 │ │
//   │  └─────────────────────────────────┘ │
//   └─────────────────────────────────────┘
//   → MTKView 绘制玻璃渐变/辉光/颗粒感
//   → SwiftUI Text 以 overlay 方式叠加
//   → 最终输出到 desktop 层级 NSWindow
//
// 路径 B — SwiftUI 原生（metalShaderEnabled = false）
//   → macOS 26+ 使用 Glass API（Metal 离屏渲染）
//   → macOS 14~25 使用 .ultraThinMaterial fallback
//
// ═══════════════════════════════════════════════════════════
// 设计意图：
// 本组件对标的是 wallpaperengine-cli.swift 中 WebRendererBridge
// （WKWebView + HTML/JS 渲染动态文本）的原生 Metal 替代方案。
// 将 web 那套（scene-bake-web-template/index.html）彻底抛弃，
// 所有时钟/日期挂件走原生 Metal 渲染管线。
// ═══════════════════════════════════════════════════════════

public struct LiquidGlassClockView: View {
    let config: LiquidGlassClockConfiguration
    /// Metal 路径下注册 MTKView 引用的回调（供 OverlayManager 暂停/恢复）
    var mtkViewRegistry: ((MTKView) -> Void)? = nil

    public init(config: LiquidGlassClockConfiguration, mtkViewRegistry: ((MTKView) -> Void)? = nil) {
        self.config = config
        self.mtkViewRegistry = mtkViewRegistry
    }

    @State private var now: Date = .init()
    /// 频谱数据（通过 Publisher 精确订阅，不走 @Published objectWillChange）
    @State private var spectrum: [Float] = Array(repeating: 0, count: 32)

    /// 每秒更新一次的定时器
    @State private var clockConsumerID = UUID()

    public init(config: LiquidGlassClockConfiguration) {
        self.config = config
    }

    public var body: some View {
        textOverlayContent
            .onReceive(WallpaperClockTicker.shared.$now) { newDate in
                // 不使用 withAnimation 包裹整个状态更新，避免玻璃背景和音频可视化走动画管线
                // 时间文字的动画由 .contentTransition(.numericText) 和 .animation 精确控制
                now = newDate
            }
            .onReceive(spectrumPublisher) { newSpectrum in
                spectrum = newSpectrum
            }
            .onAppear {
                WallpaperClockTicker.shared.acquire(clockConsumerID, seconds: config.showSeconds)
                // 初始订阅：获取当前频谱值
                spectrum = currentSpectrumSnapshot
            }
            .onDisappear { WallpaperClockTicker.shared.release(clockConsumerID) }
            .onChange(of: config.showSeconds) { _, value in WallpaperClockTicker.shared.acquire(clockConsumerID, seconds: value) }
            // audioBarCount 变化时，spectrumPublisher 会指向不同的频段 Publisher。
            // onReceive 在视图首次构建时绑定一次，不会自动重新订阅，因此用 .id 强制
            // 在频段切换时重建该视图分支，使 onReceive 重新绑定到新的 Publisher。
            .id(config.audioBarCount)
    }

    /// 根据 audioBarCount 选择对应的频谱 Publisher
    private var spectrumPublisher: AnyPublisher<[Float], Never> {
        let service = SystemAudioCaptureService.shared
        switch config.audioBarCount {
        case 16:  return service.spectrum16Publisher.eraseToAnyPublisher()
        case 64:  return service.spectrum64Publisher.eraseToAnyPublisher()
        default:  return service.spectrum32Publisher.eraseToAnyPublisher()
        }
    }

    /// 初始频谱快照（onAppear 时获取）
    private var currentSpectrumSnapshot: [Float] {
        let service = SystemAudioCaptureService.shared
        switch config.audioBarCount {
        case 16:  return service.spectrum16
        case 64:  return service.spectrum64
        default:  return service.spectrum32
        }
    }

    /// 文字内容 + 玻璃背景
    ///
    /// 路径 A (metalShaderEnabled=true)：
    ///   MTKView (Metal 着色器) 作为 background，文字 overlay 在上
    ///   路径 B (metalShaderEnabled=false)：
    ///   SwiftUI Glass API / .ultraThinMaterial 作为 background
    @ViewBuilder
    private var textOverlayContent: some View {
        if config.metalShaderEnabled {
            // ── 路径 A: Metal 着色器 ──
            // MTKView 作为背景，自动适配文字内容大小
            // 通过 mtkViewRegistry 回调注册 MTKView 引用供暂停/恢复
            textOverlay
                .padding(.horizontal, config.horizontalPadding)
                .padding(.vertical, config.verticalPadding)
                .background(
                    LiquidGlassMetalClockView(config: config, viewRegistry: mtkViewRegistry)
                        .clipShape(.rect(cornerRadius: config.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: config.cornerRadius, style: .continuous)
                                .stroke(config.accentColor.opacity(0.25), lineWidth: 1)
                                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
                        )
                )
                .clipShape(.rect(cornerRadius: config.cornerRadius, style: .continuous))
        } else {
            // ── 路径 B: SwiftUI 原生玻璃 ──
            textOverlay
                .padding(.horizontal, config.horizontalPadding)
                .padding(.vertical, config.verticalPadding)
                .modifier(ClockGlassSurfaceModifier(config: config))
        }
    }

    // MARK: - 文字叠加层

    private var textOverlay: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // 时间（主）
            Text(config.timeString(for: now))
                .font(.system(size: config.timeFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(config.accentColor.mixIn(white: 0.85, fraction: 0.3))
                .shadow(color: config.accentColor.opacity(0.3), radius: 4, x: 0, y: 2)
                .contentTransition(.numericText(countsDown: !config.use12Hour))
                .animation(config.animationEnabled ? .easeInOut(duration: 0.2) : nil,
                           value: Int(now.timeIntervalSince1970))

            // 日期 + 星期（副）
            if config.showDate || config.showWeekday {
                HStack(spacing: 6) {
                    if config.showWeekday {
                        Text(config.weekdayString(for: now))
                            .font(.system(size: config.dateFontSize, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if config.showDate {
                        Text(config.dateString(for: now))
                            .font(.system(size: config.dateFontSize, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
            }

            // 自定义文本（预留）
            if !config.customPrefix.isEmpty || !config.customSuffix.isEmpty {
                Text("\(config.customPrefix)\(config.customSuffix)")
                    .font(.system(size: config.dateFontSize - 2, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // ── 音频柱状图 ──
            if config.showAudioVisualizer {
                LiquidGlassAudioVisualizer(
                    config: config.audioVisualizerConfig,
                    spectrum: spectrum
                )
                .frame(maxWidth: 200)
                .padding(.top, 6)
            }
        }
    }
}

// MARK: - 玻璃表面修饰器（路径 B）

private struct ClockGlassSurfaceModifier: ViewModifier {
    let config: LiquidGlassClockConfiguration

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // ── 原生 Glass API（Metal 离屏渲染） ──
            let shape = RoundedRectangle(cornerRadius: config.cornerRadius, style: .continuous)
            content
                .padding(1)
                .background(
                    shape
                        .fill(.clear)
                        .glassEffect(.regular.tint(config.accentColor.opacity(0.15)), in: shape)
                )
                .clipShape(shape)
                .background(
                    shape
                        .stroke(config.accentColor.opacity(0.25), lineWidth: 1)
                        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
                )
                .opacity(config.opacity)
        } else {
            // ── Fallback 模拟玻璃（macOS 14~25） ──
            content
                .background(
                    RoundedRectangle(cornerRadius: config.cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: config.cornerRadius, style: .continuous)
                                .fill(config.accentColor.opacity(0.08))
                        )
                )
                .clipShape(.rect(cornerRadius: config.cornerRadius, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: config.cornerRadius, style: .continuous)
                        .stroke(config.accentColor.opacity(0.2), lineWidth: 1)
                        .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 6)
                )
                .opacity(config.opacity)
        }
    }
}

// MARK: - 预览

#Preview("SwiftUI 玻璃") {
    LiquidGlassClockView(config: {
        var c = LiquidGlassClockConfiguration()
        c.enabled = true
        c.format = .hhmmWithDate
        c.showDate = true
        c.showWeekday = true
        c.corner = .bottomRight
        c.accentColorHex = "8B5CF6"
        c.timeFontSize = 48
        c.dateFontSize = 16
        c.metalShaderEnabled = false
        return c
    }())
    .padding(60)
    .background(
        LinearGradient(colors: [.black, Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
    )
    .frame(width: 500, height: 250)
}

#Preview("Metal 着色器") {
    LiquidGlassClockView(config: {
        var c = LiquidGlassClockConfiguration()
        c.enabled = true
        c.format = .hhmmssWithDate
        c.showDate = true
        c.showWeekday = true
        c.corner = .bottomRight
        c.accentColorHex = "8B5CF6"
        c.timeFontSize = 48
        c.dateFontSize = 16
        c.metalShaderEnabled = true
        c.metalShaderIntensity = 0.6
        return c
    }())
    .padding(60)
    .background(
        LinearGradient(colors: [.black, Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
    )
    .frame(width: 500, height: 250)
}

// MARK: - Color 辅助

private extension Color {
    /// 混入白色，fraction=0 全原色，fraction=1 全白
    func mixIn(white: Double, fraction: Double) -> Color {
        guard fraction > 0 else { return self }
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        let r = nsColor.redComponent + (white - nsColor.redComponent) * fraction
        let g = nsColor.greenComponent + (white - nsColor.greenComponent) * fraction
        let b = nsColor.blueComponent + (white - nsColor.blueComponent) * fraction
        return Color(red: r, green: g, blue: b)
    }
}
