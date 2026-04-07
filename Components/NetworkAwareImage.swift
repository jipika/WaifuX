import SwiftUI

/// 网络感知图片组件 - 自动处理加载中、成功、失败状态
struct NetworkAwareImage<Content: View>: View {
    let url: URL?
    let priority: TaskPriority
    @ViewBuilder let content: (Image) -> Content
    
    @State private var image: NSImage?
    @State private var state: ImageLoadingState = .loading
    @State private var retryId = UUID()
    
    init(
        url: URL?,
        priority: TaskPriority = .medium,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.priority = priority
        self.content = content
    }
    
    var body: some View {
        Group {
            switch state {
            case .loading:
                SkeletonPlaceholder()
            case .success:
                if let image = image {
                    content(Image(nsImage: image))
                } else {
                    ImageErrorPlaceholder(retryAction: retryLoading)
                }
            case .failure:
                ImageErrorPlaceholder(retryAction: retryLoading)
            }
        }
        .id(retryId)
        .onAppear {
            loadImage()
        }
        .onChange(of: url) { _, _ in
            resetAndLoad()
        }
    }
    
    private func loadImage() {
        guard let url = url else {
            state = .failure
            return
        }
        
        guard state == .loading else { return }
        
        Task {
            let loader = ImageLoader.shared
            
            // 检查 URL 是否之前失败过
            if loader.hasFailedLoading(for: url) {
                // 如果用户主动重试，重置失败状态
                loader.resetFailureState(for: url)
            }
            
            if let loadedImage = await loader.loadImage(
                from: url,
                priority: priority
            ) {
                await MainActor.run {
                    self.image = loadedImage
                    self.state = .success
                }
            } else {
                await MainActor.run {
                    self.state = .failure
                }
            }
        }
    }
    
    private func retryLoading() {
        resetAndLoad()
    }
    
    private func resetAndLoad() {
        state = .loading
        image = nil
        retryId = UUID()
        loadImage()
    }
}

/// 简化版网络感知图片 - 使用默认配置
struct SimpleNetworkImage: View {
    let url: URL?
    var placeholderColor: Color = .gray.opacity(0.2)
    var cornerRadius: CGFloat = 8
    
    var body: some View {
        NetworkAwareImage(url: url) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }
}

/// 带渐进式加载的图片组件
struct ProgressiveNetworkImage<Content: View>: View {
    let thumbURL: URL?
    let fullURL: URL?
    let priority: TaskPriority
    @ViewBuilder let content: (Image, Bool) -> Content // (image, isFullImage)
    
    @State private var thumbImage: NSImage?
    @State private var fullImage: NSImage?
    @State private var state: ImageLoadingState = .loading
    @State private var retryId = UUID()
    
    init(
        thumbURL: URL?,
        fullURL: URL?,
        priority: TaskPriority = .medium,
        @ViewBuilder content: @escaping (Image, Bool) -> Content
    ) {
        self.thumbURL = thumbURL
        self.fullURL = fullURL
        self.priority = priority
        self.content = content
    }
    
    var body: some View {
        Group {
            switch state {
            case .loading:
                SkeletonPlaceholder()
            case .success:
                if let full = fullImage {
                    content(Image(nsImage: full), true)
                } else if let thumb = thumbImage {
                    content(Image(nsImage: thumb), false)
                } else {
                    ImageErrorPlaceholder(retryAction: retryLoading)
                }
            case .failure:
                if let thumb = thumbImage {
                    content(Image(nsImage: thumb), false)
                } else {
                    ImageErrorPlaceholder(retryAction: retryLoading)
                }
            }
        }
        .id(retryId)
        .onAppear {
            loadImages()
        }
    }
    
    private func loadImages() {
        Task {
            let loader = ImageLoader.shared
            
            // 先加载缩略图
            if let thumbURL = thumbURL {
                if let image = await loader.loadImage(from: thumbURL, priority: priority) {
                    await MainActor.run {
                        self.thumbImage = image
                        self.state = .success
                    }
                }
            }
            
            // 再加载高清图
            if let fullURL = fullURL, fullURL != thumbURL {
                if let image = await loader.loadImage(from: fullURL, priority: .low) {
                    await MainActor.run {
                        self.fullImage = image
                    }
                }
            }
            
            // 如果都没有加载成功
            if thumbImage == nil && fullImage == nil {
                await MainActor.run {
                    self.state = .failure
                }
            }
        }
    }
    
    private func retryLoading() {
        state = .loading
        thumbImage = nil
        fullImage = nil
        retryId = UUID()
        loadImages()
    }
}

/// 网络状态指示器
struct NetworkStatusIndicator: View {
    @ObservedObject var monitor: NetworkMonitor
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
            
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(statusColor.opacity(0.12))
        )
        .opacity(monitor.isOffline ? 1.0 : 0.7)
        .animation(.easeInOut(duration: 0.2), value: monitor.status.connectionState)
    }
    
    private var iconName: String {
        switch monitor.status.connectionState {
        case .wifi:
            return "wifi"
        case .cellular:
            return "antenna.radiowaves.left.and.right"
        case .other:
            return "network"
        case .offline:
            return "wifi.slash"
        }
    }
    
    private var statusText: String {
        switch monitor.status.connectionState {
        case .wifi:
            return t("network.wifi")
        case .cellular:
            return t("network.cellular")
        case .other:
            return t("network.connected")
        case .offline:
            return t("network.offline")
        }
    }
    
    private var statusColor: Color {
        switch monitor.status.connectionState {
        case .wifi:
            return .green
        case .cellular:
            return .blue
        case .other:
            return .green
        case .offline:
            return .orange
        }
    }
}

/// 弱网提示条
struct WeakNetworkBanner: View {
    @ObservedObject var monitor: NetworkMonitor
    var onRetry: (() -> Void)?
    
    var body: some View {
        if monitor.quality <= .fair && monitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                
                Text(t("weak.network.message"))
                    .font(.system(size: 12, weight: .medium))
                
                Spacer()
                
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Text(t("retry"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [Color.orange.opacity(0.8), Color.red.opacity(0.6)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// 离线提示遮罩
struct OfflineOverlay: View {
    @ObservedObject var monitor: NetworkMonitor
    var onRetry: (() -> Void)?
    
    var body: some View {
        if monitor.isOffline {
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.secondary)
                
                Text(t("offline.title"))
                    .font(.system(size: 18, weight: .semibold))
                
                Text(t("offline.message"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text(t("retry"))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.blue)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .transition(.opacity)
        }
    }
}

// MARK: - Preview
#Preview("Network Aware Image") {
    VStack(spacing: 20) {
        // 加载中
        NetworkAwareImage(url: nil) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
        .frame(width: 200, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        
        // 错误状态
        ImageErrorPlaceholder(retryAction: {})
            .frame(width: 200, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .padding()
}

#Preview("Network Status") {
    VStack(spacing: 20) {
        NetworkStatusIndicator(monitor: NetworkMonitor.shared)
        
        WeakNetworkBanner(monitor: NetworkMonitor.shared)
        
        OfflineOverlay(monitor: NetworkMonitor.shared) {}
    }
    .padding()
}
