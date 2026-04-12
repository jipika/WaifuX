import SwiftUI

/// 错误类型
enum ErrorDisplayType {
    case network
    case empty
    case server
    case offline
    case apiLimited
    case unknown

    var icon: String {
        switch self {
        case .network:
            return "wifi.exclamationmark"
        case .empty:
            return "tray"
        case .server:
            return "server.rack"
        case .offline:
            return "wifi.slash"
        case .apiLimited:
            return "key.slash"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }

    var defaultTitle: String {
        switch self {
        case .network:
            return t("error.network.title")
        case .empty:
            return t("error.empty.title")
        case .server:
            return t("error.server.title")
        case .offline:
            return t("error.offline.title")
        case .apiLimited:
            return t("error.apiLimited.title")
        case .unknown:
            return t("error.unknown.title")
        }
    }

    var defaultMessage: String {
        switch self {
        case .network:
            return t("error.network.message")
        case .empty:
            return t("error.empty.message")
        case .server:
            return t("error.server.message")
        case .offline:
            return t("error.offline.message")
        case .apiLimited:
            return t("error.apiLimited.message")
        case .unknown:
            return t("error.unknown.message")
        }
    }
}

/// 错误状态视图
struct ErrorStateView: View {
    let type: ErrorDisplayType
    var title: String? = nil
    var message: String? = nil
    var retryAction: (() -> Void)? = nil
    var retryTitle: String = t("retry")
    
    @State private var isHovered = false
    @State private var isRetrying = false
    
    private var displayTitle: String {
        title ?? type.defaultTitle
    }
    
    private var displayMessage: String {
        message ?? type.defaultMessage
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // 图标
            Image(systemName: type.icon)
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(iconColor)
                .symbolRenderingMode(.hierarchical)
            
            // 标题
            Text(displayTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            
            // 描述
            Text(displayMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            
            // 重试按钮
            if retryAction != nil {
                Button {
                    performRetry()
                } label: {
                    HStack(spacing: 8) {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                        }
                        Text(retryTitle)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(buttonColor)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isRetrying)
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = hovering && !isRetrying
                    }
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var iconColor: Color {
        switch type {
        case .network, .offline, .apiLimited:
            return .orange
        case .empty:
            return .secondary
        case .server:
            return .red
        case .unknown:
            return .yellow
        }
    }

    private var buttonColor: Color {
        switch type {
        case .network, .offline, .apiLimited:
            return .orange
        case .empty:
            return .secondary
        case .server:
            return .red.opacity(0.8)
        case .unknown:
            return .orange
        }
    }
    
    private func performRetry() {
        guard !isRetrying else { return }
        isRetrying = true
        
        // 延迟重置状态，给用户视觉反馈
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            retryAction?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isRetrying = false
            }
        }
    }
}

/// 图片加载状态视图
struct ImageLoadingStateView: View {
    let state: ImageLoadingState
    var retryAction: (() -> Void)? = nil
    
    var body: some View {
        switch state {
        case .loading:
            SkeletonPlaceholder()
        case .success:
            EmptyView()
        case .failure:
            ImageErrorPlaceholder(retryAction: retryAction)
        }
    }
}

/// 图片加载状态
enum ImageLoadingState {
    case loading
    case success
    case failure
}

/// 骨架屏占位符
struct SkeletonPlaceholder: View {
    @State private var isAnimating = false
    
    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [
                    Color.gray.opacity(0.15),
                    Color.gray.opacity(0.25),
                    Color.gray.opacity(0.15)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geometry.size.width * 1.5)
            .offset(x: isAnimating ? geometry.size.width : -geometry.size.width)
        }
        .clipped()
        .onAppear {
            withAnimation(
                .linear(duration: 1.5)
                .repeatForever(autoreverses: false)
            ) {
                isAnimating = true
            }
        }
    }
}

/// 图片错误占位符
struct ImageErrorPlaceholder: View {
    var retryAction: (() -> Void)? = nil
    @State private var isHovered = false
    
    var body: some View {
        ZStack {
            // 背景
            LinearGradient(
                colors: [
                    Color.gray.opacity(0.1),
                    Color.gray.opacity(0.2)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // 内容
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.secondary)
                
                if retryAction != nil {
                    Text(t("tap.to.retry"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            retryAction?()
        }
        .opacity(isHovered ? 0.8 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

/// 网络感知空状态视图
struct NetworkAwareEmptyState: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    let emptyTitle: String
    let emptyMessage: String
    let offlineTitle: String
    let offlineMessage: String
    let retryAction: () -> Void
    
    var body: some View {
        if networkMonitor.isOffline {
            ErrorStateView(
                type: .offline,
                title: offlineTitle,
                message: offlineMessage,
                retryAction: retryAction
            )
        } else {
            ErrorStateView(
                type: .empty,
                title: emptyTitle,
                message: emptyMessage,
                retryAction: retryAction
            )
        }
    }
}

// MARK: - Preview
#Preview("Error States") {
    VStack(spacing: 20) {
        ErrorStateView(
            type: .network,
            retryAction: {}
        )
        .frame(height: 200)
        
        ErrorStateView(
            type: .offline,
            retryAction: {}
        )
        .frame(height: 200)
        
        ErrorStateView(
            type: .empty
        )
        .frame(height: 200)
    }
    .padding()
}

#Preview("Image Placeholders") {
    HStack(spacing: 20) {
        SkeletonPlaceholder()
            .frame(width: 150, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        
        ImageErrorPlaceholder(retryAction: {})
            .frame(width: 150, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .padding()
}
