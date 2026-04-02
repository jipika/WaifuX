import SwiftUI

// MARK: - 弹幕视图

/// 弹幕显示视图（参考 Kazumi 的 canvas_danmaku）
struct DanmakuView: View {
    let danmakuList: [Danmaku]
    @Binding var isEnabled: Bool
    @State var settings: DanmakuSettings = .default

    // 当前播放时间（秒）
    @Binding var currentTime: Double

    // 视图尺寸
    @State private var viewSize: CGSize = .zero

    // 活跃的弹幕项
    @State private var activeItems: [DanmakuItem] = []

    // 轨道管理
    @State private var scrollTracks: [Int: Double] = [:]  // 轨道索引: 最后弹幕的结束时间
    @State private var topTracks: [Int: Bool] = [:]       // 轨道索引: 是否被占用
    @State private var bottomTracks: [Int: Bool] = [:]    // 轨道索引: 是否被占用

    // 定时器
    @State private var timer: Timer?

    // 轨道配置
    private let trackHeight: Double = 30
    private let maxTracks = 15

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 弹幕层
                ForEach(activeItems) { item in
                    DanmakuTextItemView(
                        item: item,
                        settings: settings,
                        viewWidth: geometry.size.width
                    )
                    .position(
                        x: item.x,
                        y: item.y
                    )
                    .opacity(item.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: geometry.size) { _, newSize in
                viewSize = newSize
                initializeTracks()
            }
            .onAppear {
                viewSize = geometry.size
                initializeTracks()
                startTimer()
            }
            .onDisappear {
                stopTimer()
            }
            .onChange(of: currentTime) { _, newTime in
                updateDanmaku(for: newTime)
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    activeItems.removeAll()
                }
            }
        }
        .allowsHitTesting(false)  // 允许点击穿透到视频
    }

    // MARK: - 轨道管理

    private func initializeTracks() {
        let trackCount = min(maxTracks, Int(viewSize.height / trackHeight))
        scrollTracks = Dictionary(uniqueKeysWithValues: (0..<trackCount).map { ($0, 0) })
        topTracks = Dictionary(uniqueKeysWithValues: (0..<trackCount).map { ($0, false) })
        bottomTracks = Dictionary(uniqueKeysWithValues: (0..<trackCount).map { ($0, false) })
    }

    // MARK: - 弹幕更新

    private func updateDanmaku(for time: Double) {
        guard isEnabled else { return }

        // 找到当前时间应该显示的弹幕
        let windowStart = time - 1.0  // 提前1秒准备
        let windowEnd = time + 0.5    // 允许0.5秒的延迟

        let newDanmaku = danmakuList.filter { danmaku in
            danmaku.time >= windowStart &&
            danmaku.time <= windowEnd &&
            !activeItems.contains(where: { $0.danmaku.time == danmaku.time && $0.danmaku.text == danmaku.text })
        }

        // 根据设置过滤
        let filteredDanmaku = newDanmaku.filter { danmaku in
            switch danmaku.mode {
            case .scroll:
                return settings.enableScroll
            case .top:
                return settings.enableTop
            case .bottom:
                return settings.enableBottom
            }
        }

        // 添加到活跃列表
        for danmaku in filteredDanmaku {
            if let item = createDanmakuItem(danmaku: danmaku, currentTime: time) {
                withAnimation {
                    activeItems.append(item)
                }
            }
        }

        // 清理过期的弹幕
        cleanupExpiredDanmaku(currentTime: time)
    }

    private func createDanmakuItem(danmaku: Danmaku, currentTime: Double) -> DanmakuItem? {
        let delay = currentTime - danmaku.time

        switch danmaku.mode {
        case .scroll:
            return createScrollItem(danmaku: danmaku, delay: delay)
        case .top:
            return createTopItem(danmaku: danmaku)
        case .bottom:
            return createBottomItem(danmaku: danmaku)
        }
    }

    private func createScrollItem(danmaku: Danmaku, delay: Double) -> DanmakuItem? {
        // 找到可用的轨道
        guard let trackIndex = findAvailableScrollTrack() else { return nil }

        let textWidth = estimateTextWidth(danmaku.text)
        let startX = viewSize.width + textWidth / 2
        let endX = -textWidth / 2

        // 计算当前位置（基于延迟）
        let duration = Double(danmaku.text.count) * 0.15 / settings.speed + 5.0
        let progress = max(0, delay) / duration
        let currentX = startX + (endX - startX) * progress

        let y = Double(trackIndex) * trackHeight + trackHeight / 2

        // 更新轨道状态
        let endTime = Date().timeIntervalSince1970 + duration * (1 - progress)
        scrollTracks[trackIndex] = endTime

        return DanmakuItem(
            danmaku: danmaku,
            x: currentX,
            y: y
        )
    }

    private func createTopItem(danmaku: Danmaku) -> DanmakuItem? {
        guard let trackIndex = findAvailableFixedTrack(tracks: &topTracks) else { return nil }

        let y = Double(trackIndex) * trackHeight + trackHeight / 2

        // 3秒后释放轨道
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            topTracks[trackIndex] = false
        }

        return DanmakuItem(
            danmaku: danmaku,
            x: viewSize.width / 2,
            y: y
        )
    }

    private func createBottomItem(danmaku: Danmaku) -> DanmakuItem? {
        guard let trackIndex = findAvailableFixedTrack(tracks: &bottomTracks) else { return nil }

        // 从底部往上计算
        let y = viewSize.height - (Double(trackIndex) * trackHeight + trackHeight / 2)

        // 3秒后释放轨道
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            bottomTracks[trackIndex] = false
        }

        return DanmakuItem(
            danmaku: danmaku,
            x: viewSize.width / 2,
            y: y
        )
    }

    private func findAvailableScrollTrack() -> Int? {
        let currentTime = Date().timeIntervalSince1970

        // 找到最早可用的轨道
        return scrollTracks
            .filter { $0.value <= currentTime }
            .min(by: { $0.value < $1.value })?
            .key
    }

    private func findAvailableFixedTrack(tracks: inout [Int: Bool]) -> Int? {
        return tracks.first { !$0.value }?.key
    }

    private func cleanupExpiredDanmaku(currentTime: Double) {
        let duration = 10.0  // 弹幕最大存活时间

        activeItems.removeAll { item in
            let age = currentTime - item.danmaku.time
            return age > duration
        }
    }

    // MARK: - 定时器

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            updateScrollPositions()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateScrollPositions() {
        guard isEnabled else { return }

        let deltaTime = 0.05  // 50ms
        let speed = 100.0 * settings.speed  // 基础速度 100 点/秒

        for index in activeItems.indices {
            if activeItems[index].danmaku.mode == .scroll {
                activeItems[index].x -= speed * deltaTime
            }
        }

        // 清理移出屏幕的弹幕
        activeItems.removeAll { item in
            item.x < -estimateTextWidth(item.danmaku.text)
        }
    }

    // MARK: - 辅助方法

    private func estimateTextWidth(_ text: String) -> Double {
        let charWidth = settings.fontSize * 0.8
        return Double(text.count) * charWidth
    }
}

// MARK: - 单个弹幕项视图

struct DanmakuTextItemView: View {
    let item: DanmakuItem
    let settings: DanmakuSettings
    let viewWidth: Double

    var body: some View {
        Text(item.danmaku.text)
            .font(.system(size: settings.fontSize, weight: .medium))
            .foregroundColor(danmakuColor)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 1, y: 1)
            .lineLimit(1)
    }

    private var danmakuColor: Color {
        let colorInfo = item.danmaku.color
        return Color(
            red: colorInfo.r,
            green: colorInfo.g,
            blue: colorInfo.b
        )
        .opacity(settings.opacity)
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
                Text("弹幕设置")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    isPresented = false
                }
            }
            .padding(.horizontal)

            Divider()

            // 开关
            Toggle("启用弹幕", isOn: $settings.isEnabled)
                .padding(.horizontal)

            Divider()

            // 速度
            VStack(alignment: .leading) {
                HStack {
                    Text("弹幕速度")
                    Spacer()
                    Text("\(String(format: "%.1f", settings.speed))x")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.speed, in: 0.5...2.0, step: 0.1)
            }
            .padding(.horizontal)

            // 透明度
            VStack(alignment: .leading) {
                HStack {
                    Text("弹幕透明度")
                    Spacer()
                    Text("\(Int(settings.opacity * 100))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.opacity, in: 0.1...1.0, step: 0.1)
            }
            .padding(.horizontal)

            // 字体大小
            VStack(alignment: .leading) {
                HStack {
                    Text("字体大小")
                    Spacer()
                    Text("\(Int(settings.fontSize))px")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.fontSize, in: 12...24, step: 1)
            }
            .padding(.horizontal)

            Divider()

            // 显示选项
            VStack(alignment: .leading, spacing: 12) {
                Text("显示选项")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("滚动弹幕", isOn: $settings.enableScroll)
                Toggle("顶部弹幕", isOn: $settings.enableTop)
                Toggle("底部弹幕", isOn: $settings.enableBottom)
                Toggle("弹幕去重", isOn: $settings.enableDeduplication)
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
            isEnabled: .constant(true),
            currentTime: .constant(0)
        )
    }
    .frame(width: 800, height: 400)
}
