import SwiftUI
import AVKit
import Kingfisher

// MARK: - AnimeDetailView - 与 MediaDetailSheet 风格一致

struct AnimeDetailView: View {
    let anime: AnimeSearchResult
    @Binding var isPresented: Bool
    @StateObject private var viewModel: AnimeDetailViewModel
    
    @State private var isVisible = false
    @State private var scrollOffset: CGFloat = 0
    
    // 挤压动画配置
    private let squeezeThreshold: CGFloat = 80
    private let maxSqueezeOffset: CGFloat = 120
    
    init(anime: AnimeSearchResult, isPresented: Binding<Bool>) {
        self.anime = anime
        self._isPresented = isPresented
        self._viewModel = StateObject(wrappedValue: AnimeDetailViewModel(anime: anime))
    }
    
    var body: some View {
        GeometryReader { geometry in
            let topBarTopInset = max(geometry.safeAreaInsets.top, 18)
            let bottomSafeInset = max(geometry.safeAreaInsets.bottom, 28)
            let viewW = geometry.size.width
            let viewH = geometry.size.height
            
            ZStack(alignment: .topLeading) {
                Color(hex: "0A0A0C")
                    .ignoresSafeArea()
                    .coordinateSpace(name: "scroll")
                
                if isVisible {
                    fixedAnimeBackground(width: viewW, height: viewH)
                }
                
                // 顶部和底部渐变遮罩
                gradientOverlays(viewH: viewH)
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: detailScrollTopInset(viewportHeight: viewH))
                        
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, bottomSafeInset + 88)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: ScrollOffsetPreferenceKey.self, value: proxy.frame(in: .named("scroll")).minY)
                        }
                    )
                }
                .scrollClipDisabled()
                .safeAreaPadding(.bottom, bottomSafeInset)
                .background(Color.clear)
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = value
                }
                .overlay(alignment: .top) {
                    fixedHeroChrome(viewportWidth: viewW, topBarTopInset: topBarTopInset)
                }
                
                floatingBackButton
                    .padding(.top, topBarTopInset + 18)
                    .padding(.leading, 28)
            }
        }
        .ignoresSafeArea()
        .task {
            isVisible = true
            await viewModel.loadData()
        }
        .sheet(isPresented: $viewModel.showAliasSearchSheet) {
            AliasSearchSheet(viewModel: viewModel)
        }
        .navigationBarBackButtonHidden(true)
    }
    
    // MARK: - 背景
    private func fixedAnimeBackground(width: CGFloat, height viewH: CGFloat) -> some View {
        ZStack {
            // 封面图
            KFImage(URL(string: anime.coverURL ?? ""))
                .fade(duration: 0.3)
                .placeholder { _ in
                    Color(hex: "1A1A1E")
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
            
            // 渐变遮罩
            LinearGradient(
                colors: [
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.10),
                    Color.black.opacity(0.34)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.12),
                            Color.black.opacity(0.34)
                        ],
                        center: .center,
                        startRadius: 120,
                        endRadius: max(width, viewH)
                    )
                )
        }
        .frame(width: width, height: viewH)
        .clipped()
        .ignoresSafeArea()
    }
    
    // MARK: - 渐变遮罩
    private func gradientOverlays(viewH: CGFloat) -> some View {
        ZStack {
            VStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.52), Color.black.opacity(0.18), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
                Spacer()
            }
            VStack {
                Spacer()
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.26), Color.black.opacity(0.56)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(viewH * 0.36, 440))
            }
        }
        .allowsHitTesting(false)
    }
    
    // MARK: - Hero 区域
    private func fixedHeroChrome(viewportWidth: CGFloat, topBarTopInset: CGFloat) -> some View {
        let squeezeProgress = min(max(-scrollOffset / squeezeThreshold, 0), 1)
        let scaleY = 1 - (squeezeProgress * 0.15)
        let offsetY = -squeezeProgress * maxSqueezeOffset * 0.3
        let opacity = 1 - (squeezeProgress * 0.3)
        
        return VStack(spacing: 0) {
            Spacer()
                .frame(height: max(topBarTopInset + 44, 68))
            
            VStack(spacing: 18) {
                detailCategoryBadge
                
                Text(anime.title)
                    .font(.system(size: 52, weight: .bold, design: .serif))
                    .tracking(-1.3)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 980)
                    .detailGlassTitleChrome()
                
                HStack(spacing: 0) {
                    metadataCapsules
                }
                .frame(maxWidth: .infinity, alignment: .center)
                
                buttonRowWithDividers
            }
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .frame(width: viewportWidth)
        .scaleEffect(x: 1, y: scaleY, anchor: .center)
        .offset(y: offsetY)
        .opacity(opacity)
        .animation(.easeOut(duration: 0.15), value: scrollOffset)
    }
    
    // MARK: - 返回按钮
    private var floatingBackButton: some View {
        Button { isPresented = false } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 38, height: 38)
                .detailGlassCircleChrome()
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
    
    // MARK: - 分类徽章
    private var detailCategoryBadge: some View {
        let typeText = viewModel.bangumiDetail?.typeDisplayName ?? "TV"
        let yearText = viewModel.bangumiDetail?.airDate?.prefix(4) ?? ""
        
        return Text("\(typeText) · \(yearText.isEmpty ? "动漫" : String(yearText))")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .tracking(2)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .detailGlassCapsuleChrome(level: .prominent)
    }
    
    // MARK: - 元数据胶囊
    private var metadataCapsules: some View {
        let items = metadataItems
        
        return ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            HStack(spacing: 4) {
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(item.value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .detailGlassCapsuleChrome(level: .prominent)
            .padding(.trailing, index == items.count - 1 ? 0 : 8)
        }
    }
    
    private var metadataItems: [(label: String, value: String)] {
        var items: [(String, String)] = []
        
        if let score = viewModel.bangumiDetail?.rating?.score {
            items.append(("评分", String(format: "%.1f", score)))
        }
        
        if let episodes = viewModel.bangumiDetail?.totalEpisodes, episodes > 0 {
            items.append(("集数", "\(episodes) 集"))
        }
        
        // 使用来源数量作为额外信息
        let availableSources = viewModel.sourceResults.filter { $0.status == .success }.count
        if availableSources > 0 {
            items.append(("可用源", "\(availableSources)"))
        }
        
        if let sourceCount = viewModel.sourceResults.filter({ $0.status == .success }).count as Int?, sourceCount > 0 {
            items.append(("来源", "\(sourceCount) 个源"))
        }
        
        return items
    }
    
    // MARK: - 按钮行
    private var buttonRowWithDividers: some View {
        HStack(spacing: 16) {
            HStack(spacing: 16) {
                dividerLine.frame(width: 70)
                
                // 收藏按钮
                Button {
                    viewModel.toggleFavorite()
                } label: {
                    Image(systemName: viewModel.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(viewModel.isFavorite ? Color(hex: "FF5A7D") : .white)
                        .frame(width: 42, height: 42)
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            }
            
            // 开始观看/继续观看按钮
            Button {
                // 使用 AnimeWindowManager 打开独立窗口（传入当前 ViewModel）
                AnimeWindowManager.shared.openPlayerWindow(for: anime, using: viewModel)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.lastPlayedEpisode != nil ? "play.circle.fill" : "play.fill")
                        .font(.system(size: 13, weight: .medium))
                    Text(viewModel.lastPlayedEpisode != nil ? "继续观看" : "开始观看")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(height: 46)
                .detailPrimaryGlassButtonChrome()
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))
            
            HStack(spacing: 16) {
                // 别名搜索按钮
                Button {
                    if let firstSource = viewModel.sourceResults.first {
                        viewModel.showAliasSearch(for: firstSource.rule)
                    }
                } label: {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .detailGlassCircleChrome()
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                
                dividerLine.frame(width: 70)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .glassContainer(spacing: 16)
    }
    
    private var dividerLine: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.25), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
    

    private func detailScrollTopInset(viewportHeight: CGFloat) -> CGFloat {
        return max(min(viewportHeight * 0.58, 520), 420)
    }
}




// MARK: - 别名搜索弹窗
private struct AliasSearchSheet: View {
    @ObservedObject var viewModel: AnimeDetailViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color(hex: "3B8BFF"))
                
                Text(t("anime.aliasSearch"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            
            if !viewModel.bangumiAliases.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("anime.selectAlias"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    
                    FlowLayout(spacing: 10) {
                        ForEach(viewModel.bangumiAliases.prefix(5), id: \.self) { alias in
                            Button(action: {
                                if let rule = viewModel.aliasSearchRule {
                                    dismiss()
                                    Task {
                                        await viewModel.retrySearchWithAlias(alias, for: rule)
                                    }
                                }
                            }) {
                                Text(alias)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Capsule())
                            }
                            .detailGlassCapsuleChrome(level: .regular)
                        }
                    }
                }
            }
            
            Divider()
                .background(.white.opacity(0.1))
            
            VStack(alignment: .leading, spacing: 12) {
                Text(t("anime.orManualInput"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                
                LiquidGlassTextField(
                    t("anime.aliasInputPlaceholder"),
                    text: $viewModel.aliasSearchText,
                    icon: "textformat"
                )
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                Button(action: { dismiss() }) {
                    Text(t("cancel"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .contentShape(Capsule())
                }
                .detailGlassCapsuleChrome(level: .regular)
                
                Button(action: {
                    if let rule = viewModel.aliasSearchRule {
                        let keyword = viewModel.aliasSearchText.trimmingCharacters(in: .whitespaces)
                        dismiss()
                        if !keyword.isEmpty {
                            Task {
                                await viewModel.retrySearchWithAlias(keyword, for: rule)
                            }
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text(t("general.search"))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
                }
                .detailPrimaryGlassButtonChrome()
            }
        }
        .padding(24)
        .frame(width: 400, height: viewModel.bangumiAliases.isEmpty ? 280 : 420)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.black.opacity(0.7))
                .background(.ultraThinMaterial)
        )
    }
}

// MARK: - 验证码输入弹窗
struct CaptchaInputSheet: View {
    let rule: AnimeRule
    let captchaImageURL: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    
    @State private var captchaCode: String = ""
    @State private var isLoading: Bool = false
    
    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color(hex: "3B8BFF"))
                
                Text(t("captcha.pleaseEnter"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            
            Text(t("captcha.sourceRequires"))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            
            // 验证码图片
            if let url = URL(string: captchaImageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(height: 60)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.05))
                .cornerRadius(8)
            }
            
            HStack(spacing: 12) {
                LiquidGlassTextField(
                    "验证码",
                    text: $captchaCode,
                    icon: "number",
                    onSubmit: submit
                )
                
                Button(action: { captchaCode = "" }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .detailGlassCircleChrome()
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                Button(action: onCancel) {
                    Text(t("cancel"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .contentShape(Capsule())
                }
                .detailGlassCapsuleChrome(level: .regular)
                
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        }
                        Text(t("general.confirm"))
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
                }
                .detailPrimaryGlassButtonChrome()
                .disabled(captchaCode.isEmpty || isLoading)
            }
        }
        .padding(28)
        .frame(width: 380, height: 340)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.black.opacity(0.7))
                .background(.ultraThinMaterial)
        )
    }
    
    private func submit() {
        let code = captchaCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        isLoading = true
        onSubmit(code)
    }
}
