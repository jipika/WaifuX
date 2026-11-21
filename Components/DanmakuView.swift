import SwiftUI

/// Draws only the current media-time window. Playback's existing time observer drives redraws;
/// no independent timer or implicit animation can keep comments moving while paused.
struct DanmakuView: View {
    let danmakuList: [Danmaku]
    let settings: DanmakuSettings
    let currentTime: Double
    let isPlaying: Bool
    let playbackRate: Double

    @State private var timeline = AnimeDanmakuTimeline()

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let offset = settings.timeOffset.isFinite ? settings.timeOffset : 0
                let mediaTime = currentTime - offset
                let style = AnimeDanmakuTimeline.Style(settings: settings)
                let opacity = settings.opacity.isFinite ? min(1, max(0, settings.opacity)) : 0.8
                let weight = Self.fontWeight(settings.fontWeight)
                let outline = settings.showBorder
                    ? min(3, max(0.1, settings.borderWidth.isFinite ? settings.borderWidth : 1))
                    : 0
                // 不跟随倍速时：墙上年龄 = 媒体年龄 × 倍率；停留时长按墙上秒计（entry.duration），
                // 因此媒体时间里的可见窗口为 duration / rate。
                let rate = (playbackRate.isFinite && playbackRate > 0) ? playbackRate : 1
                for entry in timeline.visibleEntries(at: mediaTime, lifetimeScale: 1 / rate) {
                    let age = mediaTime - entry.start
                    let effectiveAge = age * rate
                    guard effectiveAge >= 0, effectiveAge < entry.duration else { continue }
                    let color = settings.allowColor ? entry.danmaku.color : .white
                    let position = CGPoint(x: entry.x(at: entry.start + effectiveAge, width: size.width), y: entry.y)
                    // 描边：四向偏移绘制黑色底字，再叠加正文（canvas_danmaku 同款效果）。
                    if outline > 0 {
                        let strokeText = Text(entry.text)
                            .font(.system(size: style.fontSize, weight: weight))
                            .foregroundStyle(Color.black)
                        var stroke = context
                        stroke.opacity = opacity * 0.9
                        let resolvedStroke = stroke.resolve(strokeText)
                        for delta in [CGPoint(x: -outline, y: 0), CGPoint(x: outline, y: 0),
                                      CGPoint(x: 0, y: -outline), CGPoint(x: 0, y: outline)] {
                            stroke.draw(resolvedStroke,
                                        at: CGPoint(x: position.x + delta.x, y: position.y + delta.y),
                                        anchor: .center)
                        }
                    }
                    let text = Text(entry.text)
                        .font(.system(size: style.fontSize, weight: weight))
                        .foregroundStyle(Color(red: color.r, green: color.g, blue: color.b))
                    var drawing = context
                    drawing.opacity = opacity
                    if outline == 0 {
                        drawing.addFilter(.shadow(color: .black.opacity(0.9), radius: 1))
                    }
                    drawing.draw(drawing.resolve(text), at: position, anchor: .center)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transaction { $0.animation = nil }
            .onAppear { rebuild(size: geometry.size) }
            .onChange(of: geometry.size) { _, _ in rebuild(size: geometry.size) }
            .onChange(of: danmakuList) { _, _ in rebuild(size: geometry.size) }
            .onChange(of: AnimeDanmakuTimeline.Style(settings: settings)) { _, _ in
                rebuild(size: geometry.size)
            }
        }
    }

    private func rebuild(size: CGSize) {
        timeline = AnimeDanmakuTimeline(danmakuList: danmakuList, settings: settings,
                                       width: size.width, height: size.height)
    }

    /// 1–9 字重档位映射（Kazumi danmakuFontWeight 同刻度）。
    static func fontWeight(_ value: Int) -> Font.Weight {
        switch value {
        case ...1: return .ultraLight
        case 2: return .thin
        case 3: return .light
        case 4: return .regular
        case 5: return .medium
        case 6: return .semibold
        case 7: return .bold
        case 8: return .heavy
        default: return .black
        }
    }
}

// MARK: - 弹幕控制面板

struct DanmakuControlPanel: View {
    @Binding var settings: DanmakuSettings
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            // 标题栏
            HStack {
                Text(t("danmaku.settings"))
                    .font(.headline)
                Spacer()
                Button(t("done")) {
                    isPresented = false
                }
            }
            .padding(.horizontal)

            Divider()

            // 开关
            DanmakuLiquidToggle(t("danmaku.enableDanmaku"), isOn: $settings.isEnabled)
                .padding(.horizontal)

            Divider()

            // 速度
            VStack(alignment: .leading) {
                HStack {
                    Text(t("danmaku.speed"))
                    Spacer()
                    Text("\(String(format: "%.1f", settings.speed))x")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.speed, in: 0.5...2.0, step: 0.1)
                    .tint(LiquidGlassColors.primaryPink)
            }
            .padding(.horizontal)

            // 透明度
            VStack(alignment: .leading) {
                HStack {
                    Text(t("danmaku.opacity"))
                    Spacer()
                    Text("\(Int(settings.opacity * 100))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.opacity, in: 0.1...1.0, step: 0.1)
                    .tint(LiquidGlassColors.primaryPink)
            }
            .padding(.horizontal)

            // 字体大小
            VStack(alignment: .leading) {
                HStack {
                    Text(t("danmaku.fontSize"))
                    Spacer()
                    Text("\(Int(settings.fontSize))px")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.fontSize, in: 12...24, step: 1)
                    .tint(LiquidGlassColors.primaryPink)
            }
            .padding(.horizontal)

            Divider()

            // 显示选项
            VStack(alignment: .leading, spacing: 10) {
                Text(t("danmaku.displayOptions"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                DanmakuLiquidToggle(t("danmaku.scroll"), isOn: $settings.enableScroll)
                DanmakuLiquidToggle(t("danmaku.top"), isOn: $settings.enableTop)
                DanmakuLiquidToggle(t("danmaku.bottom"), isOn: $settings.enableBottom)
                DanmakuLiquidToggle(t("danmaku.deduplication"), isOn: $settings.enableDeduplication)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.vertical)
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
}

// MARK: - 弹幕液态玻璃 Toggle
private struct DanmakuLiquidToggle: View {
    let title: String
    @Binding var isOn: Bool
    @State private var isHovered = false
    @State private var isPressed = false

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Color(hex: "FF3366") : .white.opacity(0.4))
                    .contentTransition(.symbolEffect(.replace))

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }

            Spacer()

            // 液态玻璃开关
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    isOn.toggle()
                }
            }) {
                ZStack {
                    Capsule()
                        .fill(isOn ? Color(hex: "FF3366").opacity(0.35) : Color.white.opacity(0.12))
                        .frame(width: 40, height: 22)

                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                        .offset(x: isOn ? 9 : -9)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
                        )
                }
            }
            .buttonStyle(.plain)
            .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 弹幕开关按钮

struct DanmakuToggleButton: View {
    @Binding var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isEnabled ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isEnabled ? .yellow : .white)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 预览

#Preview {
    ZStack {
        Color.black

        DanmakuView(
            danmakuList: [
                Danmaku(text: "测试弹幕1", time: 0, mode: .scroll, color: 0xFFFFFF),
                Danmaku(text: "测试弹幕2", time: 1, mode: .scroll, color: 0xFF0000),
                Danmaku(text: "顶部弹幕", time: 2, mode: .top, color: 0x00FF00),
                Danmaku(text: "底部弹幕", time: 3, mode: .bottom, color: 0x0000FF),
            ],
            settings: .default,
            currentTime: 2.5,
            isPlaying: false,
            playbackRate: 1
        )
    }
    .frame(width: 800, height: 400)
}
