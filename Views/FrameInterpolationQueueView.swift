import SwiftUI
import AppKit

@MainActor
final class FrameInterpolationQueueWindowRoute: ObservableObject {
    static let shared = FrameInterpolationQueueWindowRoute()
    @Published var showsSkipped = false
}

struct FrameInterpolationQueueView: View {
    @ObservedObject private var queue = FrameInterpolationQueueService.shared
    @ObservedObject private var route = FrameInterpolationQueueWindowRoute.shared
    @State private var selectedPage: FrameInterpolationQueuePage = .queue

    init(showsSkipped: Bool = false) {
        _selectedPage = State(initialValue: showsSkipped ? .skipped : .queue)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().background(Color.white.opacity(0.08))

            Group {
                switch selectedPage {
                case .queue:
                    queueContent
                case .skipped:
                    skippedContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        LiquidGlassColors.deepBackground.opacity(0.98),
                        Color.black.opacity(0.94)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(LiquidGlassColors.deepBackground)
        .onAppear {
            queue.refreshSuppressedAutoQueueItems()
        }
        .onChange(of: route.showsSkipped) { showsSkipped in
            selectedPage = showsSkipped ? .skipped : .queue
            if showsSkipped {
                queue.refreshSuppressedAutoQueueItems()
            }
        }
    }

    private var header: some View {
        ZStack {
            pageSwitch

            HStack {
                Spacer()
                headerActions
            }
            .padding(.trailing, 28)
        }
        .frame(height: 64)
        .background(
            Rectangle()
                .fill(Color.white.opacity(0.02))
                .liquidGlassSurface(.subtle, tint: Color.white.opacity(0.03), in: Rectangle())
        )
    }

    private var headerSubtitle: String {
        switch selectedPage {
        case .queue:
            return queue.isQueuePaused ? "队列已暂停" : "按添加顺序离线处理"
        case .skipped:
            return "不再自动排队的视频"
        }
    }

    private var pageSwitch: some View {
        HStack(spacing: 0) {
            FrameInterpolationPageButton(
                title: "补帧队列",
                icon: "list.bullet.rectangle.portrait",
                isSelected: selectedPage == .queue
            ) {
                route.showsSkipped = false
                selectedPage = .queue
            }

            FrameInterpolationPageButton(
                title: "已跳过",
                icon: "forward.end.fill",
                isSelected: selectedPage == .skipped
            ) {
                queue.refreshSuppressedAutoQueueItems()
                route.showsSkipped = true
                selectedPage = .skipped
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .liquidGlassSurface(.prominent, tint: Color.black.opacity(0.18), in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 8) {
            switch selectedPage {
            case .queue:
                FrameInterpolationGlassButton(
                    title: queue.isQueuePaused ? "全部继续" : "全部暂停",
                    icon: queue.isQueuePaused ? "play.fill" : "pause.fill",
                    tint: queue.isQueuePaused ? Color(hex: "30D158") : Color(hex: "FFD60A")
                ) {
                    queue.isQueuePaused ? queue.resumeQueue() : queue.pauseQueue()
                }

                FrameInterpolationGlassButton(
                    title: "清理已完成",
                    icon: "checkmark.circle",
                    tint: Color.white.opacity(0.08)
                ) {
                    queue.clearCompleted()
                }

            case .skipped:
                FrameInterpolationGlassButton(
                    title: "刷新",
                    icon: "arrow.clockwise",
                    tint: LiquidGlassColors.accentCyan
                ) {
                    queue.refreshSuppressedAutoQueueItems()
                }
            }
        }
    }

    @ViewBuilder
    private var queueContent: some View {
        if queue.items.isEmpty {
            FrameInterpolationEmptyState(
                icon: "tray",
                title: "补帧队列为空",
                message: "在壁纸详情的更多菜单中添加，或开启切换壁纸时自动排队。"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(queue.items) { item in
                        FrameInterpolationQueueRow(item: item)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var skippedContent: some View {
        let items = queue.suppressedAutoQueueItems.sorted { $0.suppressedAt > $1.suppressedAt }
        if items.isEmpty {
            FrameInterpolationEmptyState(
                icon: "forward.end",
                title: "没有跳过记录",
                message: "删除补帧文件后，这里会记录不再自动排队的视频。"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(items) { item in
                        FrameInterpolationSkippedRow(item: item)
                    }
                }
                .padding(16)
            }
        }
    }
}

private enum FrameInterpolationQueuePage {
    case queue
    case skipped

    var icon: String {
        switch self {
        case .queue: return "list.bullet.rectangle.portrait"
        case .skipped: return "forward.end.fill"
        }
    }

    var tint: Color {
        switch self {
        case .queue: return LiquidGlassColors.accentCyan
        case .skipped: return LiquidGlassColors.primaryPink
        }
    }
}

private struct FrameInterpolationQueueRow: View {
    @ObservedObject private var queue = FrameInterpolationQueueService.shared
    let item: FrameInterpolationQueueItem

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                thumbnailView
                    .frame(width: 82, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.textPrimary)
                            .lineLimit(1)

                        Text(item.source.rawValue)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LiquidGlassColors.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .liquidGlassSurface(.subtle, tint: Color.white.opacity(0.05), in: Capsule())

                        Spacer()

                        Text(item.statusText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }

                    Text("\(sourceFPSLabel) -> \(item.targetFPS) FPS · optical-flow · \(item.videoURL.lastPathComponent)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                        .lineLimit(1)

                    stageView
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(statusColor.opacity(0.85))
                        .lineLimit(1)

                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(LiquidGlassColors.accentCyan)

                    HStack(spacing: 14) {
                        Text("\(Int((item.progress * 100).rounded()))%")
                        Text("帧 \(item.writtenFrames)/\(item.totalFrames.map(String.init) ?? "未知")")
                        Text("光流帧 \(item.opticalFlowFrames)")
                        Text("耗时 \(formatSeconds(item.elapsedSeconds))")
                        Text("剩余 \(item.remainingSeconds.map(formatSeconds) ?? "未知")")
                    }
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if isRunning {
                    FrameInterpolationGlassButton(title: "暂停", icon: "pause.fill", tint: Color(hex: "FFD60A")) {
                        confirmPause()
                    }
                } else if isPaused {
                    FrameInterpolationGlassButton(title: "继续", icon: "play.fill", tint: Color(hex: "30D158")) {
                        queue.resumeItem(id: item.id)
                    }
                } else if isFailed {
                    FrameInterpolationGlassButton(title: "重试", icon: "arrow.clockwise", tint: LiquidGlassColors.accentCyan) {
                        queue.retryItem(id: item.id)
                    }
                }

                FrameInterpolationGlassButton(title: "删除", icon: "trash", tint: Color(hex: "FF453A"), isDestructive: true) {
                    queue.deleteItem(id: item.id)
                }
            }
        }
        .padding(14)
        .liquidGlassSurface(.regular, tint: Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    private var sourceFPSLabel: String {
        item.sourceFPS.map { String(format: "%.2f", $0) } ?? "未知"
    }

    @ViewBuilder
    private var stageView: some View {
        if let warpStage = parsedWarpStage {
            HStack(spacing: 0) {
                Text("正在 warp 第 ")
                Text(warpStage.frame)
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
                Text(" 个 optical-flow 中间帧（源帧对 ")
                Text(warpStage.sourcePair)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                Text("，alpha=")
                Text(warpStage.alpha)
                    .monospacedDigit()
                    .frame(width: 30, alignment: .leading)
                Text("）")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let sourcePair = parsedFlowSourcePair {
            HStack(spacing: 0) {
                Text("正在计算源帧对 ")
                Text(sourcePair)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                Text(" 的 optical-flow 场")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(item.currentStage)
        }
    }

    private var parsedWarpStage: (frame: String, sourcePair: String, alpha: String)? {
        let prefix = "正在 warp 第 "
        let middle = " 个 optical-flow 中间帧（源帧对 "
        let alphaMarker = "，alpha="
        guard item.currentStage.hasPrefix(prefix) else { return nil }

        let afterPrefix = item.currentStage.dropFirst(prefix.count)
        guard let frameEnd = afterPrefix.range(of: middle) else { return nil }
        let frame = String(afterPrefix[..<frameEnd.lowerBound])
        let afterMiddle = afterPrefix[frameEnd.upperBound...]
        guard let sourcePairEnd = afterMiddle.range(of: alphaMarker) else { return nil }
        let sourcePair = String(afterMiddle[..<sourcePairEnd.lowerBound])
        let afterAlpha = afterMiddle[sourcePairEnd.upperBound...]
        guard let alphaEnd = afterAlpha.firstIndex(of: "）") else { return nil }
        let alpha = String(afterAlpha[..<alphaEnd])
        return (frame, sourcePair, alpha)
    }

    private var parsedFlowSourcePair: String? {
        let prefix = "正在计算源帧对 "
        let suffix = " 的 optical-flow 场"
        guard item.currentStage.hasPrefix(prefix),
              item.currentStage.hasSuffix(suffix) else { return nil }
        let afterPrefix = item.currentStage.dropFirst(prefix.count)
        let sourcePair = String(afterPrefix.dropLast(suffix.count))
        return sourcePair.isEmpty ? nil : sourcePair
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnailURL = item.processingThumbnailURL,
           let image = NSImage(contentsOf: thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            FrameInterpolationThumbnailPlaceholder()
        }
    }

    private var isRunning: Bool {
        if case .running = item.status { return true }
        if case .analyzing = item.status { return true }
        return false
    }

    private var isPaused: Bool {
        if case .paused = item.status { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return Color(hex: "30D158")
        case .failed: return Color(hex: "FF453A")
        case .paused: return Color(hex: "FFD60A")
        case .running, .analyzing: return LiquidGlassColors.accentCyan
        case .waiting: return LiquidGlassColors.textSecondary
        }
    }

    private func confirmPause() {
        let alert = NSAlert()
        alert.messageText = "暂停补帧任务？"
        alert.informativeText = "当前导出的临时缓存会被取消并删除。之后点击继续时，这个视频会从头开始补帧。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "暂停")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            queue.pauseItem(id: item.id)
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "未知" }
        if seconds < 60 { return "\(String(format: "%.1f", seconds))s" }
        return "\(Int(seconds) / 60)m\(Int(seconds) % 60)s"
    }
}

private struct FrameInterpolationSkippedRow: View {
    @ObservedObject private var queue = FrameInterpolationQueueService.shared
    let item: FrameInterpolationSuppressedItem

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
                .frame(width: 82, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                        .lineLimit(1)

                    Text("\(item.targetFPS) FPS")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .liquidGlassSurface(.subtle, tint: Color.white.opacity(0.05), in: Capsule())
                }

                Text(item.videoURL.lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
                    .lineLimit(1)

                Text("跳过时间 \(Self.dateFormatter.string(from: item.suppressedAt))")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            }

            Spacer()

            FrameInterpolationGlassButton(title: "删除", icon: "trash", tint: Color(hex: "FF453A"), isDestructive: true) {
                queue.removeSuppressedAutoQueueItem(id: item.id)
            }
        }
        .padding(14)
        .liquidGlassSurface(.regular, tint: LiquidGlassColors.primaryPink.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LiquidGlassColors.primaryPink.opacity(0.16), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnailURL = item.thumbnailURL,
           let image = NSImage(contentsOf: thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            FrameInterpolationThumbnailPlaceholder()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private struct FrameInterpolationPageButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(labelColor)
            .frame(width: 118, height: 36)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .liquidGlassSurface(.max, tint: Color.black.opacity(0.18), in: Capsule(style: .continuous))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.34),
                                            Color.white.opacity(0.12),
                                            Color.white.opacity(0.24)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                } else if isHovering {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.05))
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
    }

    private var labelColor: Color {
        if isSelected {
            return .white.opacity(0.96)
        }
        if isHovering {
            return .white.opacity(0.86)
        }
        return .white.opacity(0.72)
    }
}

private struct FrameInterpolationGlassButton: View {
    let title: String
    let icon: String
    let tint: Color
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 13)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isDestructive ? tint.opacity(0.95) : LiquidGlassColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 82)
            .liquidGlassSurface(.regular, tint: tint.opacity(isDestructive ? 0.12 : 0.16), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FrameInterpolationEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(LiquidGlassColors.textTertiary)
                .frame(width: 64, height: 64)
                .liquidGlassSurface(.regular, tint: Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LiquidGlassColors.textPrimary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(LiquidGlassColors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct FrameInterpolationThumbnailPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(
                Image(systemName: "film")
                    .font(.system(size: 20))
                    .foregroundStyle(LiquidGlassColors.textTertiary)
            )
            .liquidGlassSurface(.subtle, tint: Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
