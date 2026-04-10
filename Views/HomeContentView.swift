import SwiftUI
import Kingfisher

// MARK: - CarouselTimerManager（管理轮播定时器的引用类型）
@MainActor
final class CarouselTimerManager: ObservableObject {
    var timer: Timer?
    var loopResetWorkItem: DispatchWorkItem?
    var interactionResetWorkItem: DispatchWorkItem?
    
    nonisolated deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
            loopResetWorkItem?.cancel()
            interactionResetWorkItem?.cancel()
        }
    }
    
    func invalidateAll() {
        timer?.invalidate()
        timer = nil
        loopResetWorkItem?.cancel()
        loopResetWorkItem = nil
        interactionResetWorkItem?.cancel()
        interactionResetWorkItem = nil
    }
}

struct HomeContentView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @ObservedObject var mediaViewModel: MediaExploreViewModel
    @Binding var selectedWallpaper: Wallpaper?
    @Binding var selectedMedia: MediaItem?

    @State private var currentCarouselIndex = 0
    @State private var currentCarouselDisplayIndex = 0
    @State private var currentHeroID: String?
    @StateObject private var timerManager = CarouselTimerManager()
    @State private var isCarouselInteracting = false
    @State private var isCarouselAnimating = false
    @State private var carouselDragOffset: CGFloat = 0
    
    // 优化：缓存 heroPalette 避免每次访问都重新计算
    @State private var cachedHeroPalette: HeroDrivenPalette = HeroDrivenPalette(wallpaper: nil)

    private let heroHeight: CGFloat = 620
    private let carouselAutoPlayInterval: TimeInterval = 6.0
    private let carouselPageSnapDuration: TimeInterval = 0.32
    private let carouselDragThresholdRatio: CGFloat = 0.18
    private let contentHorizontalInset: CGFloat = 26
    private let sectionTopSpacing: CGFloat = 8
    
    /// 使用缓存的调色板，减少重复计算
    private var heroPalette: HeroDrivenPalette {
        cachedHeroPalette
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                heroSection
                    .zIndex(1)

                contentSections
                    .padding(.horizontal, contentHorizontalInset)
                    .padding(.top, sectionTopSpacing)
            }
            .padding(.bottom, 42)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: geometry.frame(in: .named("homeScrollView")).minY
                        )
                }
            )
        }
        .coordinateSpace(name: "homeScrollView")
        .scrollClipDisabled()
        .background(
            homeBackground
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.75), value: currentHeroID)
        )
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
            handleScroll(offset: offset)
        }
        .onAppear {
            syncCarouselState(with: heroWallpapers)
            startCarouselAutoPlay()

            // ⚠️ 延迟加载媒体数据，让首屏先渲染
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                await mediaViewModel.initialLoadIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperDataSourceChanged)) { _ in
            Task { @MainActor in
                await viewModel.refresh()
            }
        }
        .onDisappear {
            stopCarouselAutoPlay()
            cancelCarouselLoopReset()
            cancelCarouselInteractionReset()
        }
        .onChange(of: heroWallpaperIDs) { _, _ in
            syncCarouselState(with: heroWallpapers)
            stopCarouselAutoPlay()
            startCarouselAutoPlay()
        }
    }

    // MARK: - 滚动处理
    private func handleScroll(offset: CGFloat) {
        // 滚动速度检测已移除（状态切换本身会导致卡顿）
    }

    private var heroSection: some View {
        GeometryReader { geometry in
            let wallpapers = heroWallpapers
            // ⚠️ 使用 GeometryReader 的实际宽度，不应用 fallback
            // 首次布局时 geometry.size.width 可能为 0，但这是正确的，
            // 使用 max 会导致骨架屏比窗口还宽
            let width = geometry.size.width
            let heroCaptionLeadingInset = max(112, width * 0.1)
            let heroCaptionTrailingInset = max(96, width * 0.08)

            ZStack {
                if wallpapers.isEmpty {
                    HeroSkeletonView(width: width, height: heroHeight)
                } else {
                    heroCarousel(width: width, wallpapers: wallpapers)

                    if let wallpaper = currentHeroWallpaper {
                        HeroCaptionPanel(
                            wallpaper: wallpaper,
                            isFavorite: viewModel.isFavorite(wallpaper),
                            onOpen: { selectedWallpaper = wallpaper },
                            onFavorite: { viewModel.toggleFavorite(wallpaper) }
                        )
                        .frame(maxWidth: min(width * 0.42, 520), alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, heroCaptionLeadingInset)
                        .padding(.trailing, heroCaptionTrailingInset)
                        // 轮播切换只需要位移动画，避免信息面板尺寸也参与事务采样。
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }

                    VStack {
                        Spacer()
                        if wallpapers.count > 1 {
                            HeroPaginationDots(
                                count: wallpapers.count,
                                currentIndex: currentCarouselIndex,
                                onSelect: { index in
                                    selectHero(at: index)
                                }
                            )
                            .padding(.bottom, 24)
                        }
                    }

                    if wallpapers.count > 1 {
                        HStack {
                            HeroEdgeButton(direction: .previous) {
                                showPreviousHero()
                            }

                            Spacer()

                            HeroEdgeButton(direction: .next) {
                                showNextHero()
                            }
                        }
                        .padding(.horizontal, 26)
                    }
                }

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.clear,
                                heroPalette.backdropTop.opacity(0.12),
                                heroPalette.backdropMid.opacity(0.26),
                                Color.black.opacity(0.44)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: heroHeight)
            .clipped()
        }
        .frame(height: heroHeight)
    }

    private func heroCarousel(width: CGFloat, wallpapers: [Wallpaper]) -> some View {
        let displayWallpapers = carouselDisplayWallpapers(from: wallpapers)

        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(displayWallpapers.enumerated()), id: \.offset) { _, wallpaper in
                    HeroWallpaperImageSlide(
                        wallpaper: wallpaper,
                        isCurrent: wallpaper.id == currentHeroID
                    )
                    .frame(width: width, height: heroHeight)
                }
            }
            .offset(x: -CGFloat(currentCarouselDisplayIndex) * width + carouselDragOffset)
        }
        .frame(width: width, height: heroHeight, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
        .simultaneousGesture(
            heroCarouselDragGesture(width: width)
        )
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 38) {
            // 热门动态壁纸
            HomeMediaSection(
                title: t("hotDynamic"),
                mediaItems: Array(mediaViewModel.items.prefix(10)),
                onSelect: { item in
                    selectedMedia = item
                }
            )

            // 最新静态壁纸
            HomeShelfSection(
                title: t("latestWallpaper"),
                wallpapers: recentWallpapers,
                onSelect: { wallpaper in
                    selectedWallpaper = wallpaper
                }
            )
        }
        .padding(.top, 18)
        .background(alignment: .top) {
            ZStack {
                LinearGradient(
                    colors: [
                        heroPalette.backdropTop.opacity(0.28),
                        heroPalette.backdropMid.opacity(0.18),
                        Color.black.opacity(0.04),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                heroPalette.primary.opacity(0.2),
                                heroPalette.secondary.opacity(0.08),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 260
                        )
                    )
                    .frame(width: 760, height: 760)
                    .blur(radius: 120)
                    .offset(x: -80, y: -110)
            }
            .frame(height: 240)
            .padding(.top, -46)
                .allowsHitTesting(false)
        }
    }

    private var homeBackground: some View {
        let palette = heroPalette

        return ZStack {
            Color.black

            LinearGradient(
                colors: [
                    palette.backdropTop,
                    palette.backdropMid,
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.primary.opacity(0.65),
                            palette.primary.opacity(0.30),
                            palette.primary.opacity(0.08),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 380
                    )
                )
                .frame(width: 900, height: 900)
                .blur(radius: 80)
                .offset(x: -80, y: -280)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.secondary.opacity(0.55),
                            palette.secondary.opacity(0.22),
                            palette.secondary.opacity(0.06),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 420
                    )
                )
                .frame(width: 1000, height: 1000)
                .blur(radius: 100)
                .offset(x: 300, y: -200)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.tertiary.opacity(0.45),
                            palette.tertiary.opacity(0.18),
                            palette.tertiary.opacity(0.05),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 350
                    )
                )
                .frame(width: 800, height: 800)
                .blur(radius: 90)
                .offset(x: 50, y: 250)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.primary.opacity(0.40),
                            palette.secondary.opacity(0.20),
                            palette.tertiary.opacity(0.08),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 450
                    )
                )
                .frame(width: 1100, height: 1100)
                .blur(radius: 110)
                .offset(x: -150, y: 380)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.20),
                            Color.black.opacity(0.45)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        // 使用 drawingGroup 将多个模糊层合并为单一离屏渲染通道，大幅减少 GPU 合成开销
        .drawingGroup()
    }

    private var heroWallpapers: [Wallpaper] {
        let featured = Array(viewModel.featuredWallpapers.prefix(8))
        if !featured.isEmpty {
            return featured
        }

        let top = Array(viewModel.topWallpapers.prefix(8))
        if !top.isEmpty {
            return top
        }

        return Array(viewModel.wallpapers.prefix(8))
    }

    private var heroWallpaperIDs: [String] {
        heroWallpapers.map(\.id)
    }

    private func carouselDisplayWallpapers(from wallpapers: [Wallpaper]) -> [Wallpaper] {
        guard
            wallpapers.count > 1,
            let firstWallpaper = wallpapers.first,
            let lastWallpaper = wallpapers.last
        else {
            return wallpapers
        }

        return [lastWallpaper] + wallpapers + [firstWallpaper]
    }

    private var currentHeroWallpaper: Wallpaper? {
        guard !heroWallpapers.isEmpty else { return nil }
        let clampedIndex = min(max(currentCarouselIndex, 0), heroWallpapers.count - 1)
        return heroWallpapers[clampedIndex]
    }
    
    /// 更新缓存的调色板（只在壁纸变化时调用）
    private func updateCachedHeroPalette() {
        let newPalette = HeroDrivenPalette(wallpaper: currentHeroWallpaper)
        // 只在颜色真正变化时才更新，避免不必要的刷新
        if newPalette.primary != cachedHeroPalette.primary ||
           newPalette.secondary != cachedHeroPalette.secondary ||
           newPalette.tertiary != cachedHeroPalette.tertiary {
            withAnimation(.easeInOut(duration: 0.75)) {
                cachedHeroPalette = newPalette
            }
        }
    }

    private var recentWallpapers: [Wallpaper] {
        let latest = Array(viewModel.latestWallpapers.prefix(10))
        if !latest.isEmpty {
            return latest
        }
        return Array(viewModel.wallpapers.suffix(10))
    }

    private func syncCarouselState(with wallpapers: [Wallpaper]) {
        cancelCarouselLoopReset()
        cancelCarouselInteractionReset()

        guard !wallpapers.isEmpty else {
            currentCarouselIndex = 0
            currentCarouselDisplayIndex = 0
            currentHeroID = nil
            isCarouselInteracting = false
            isCarouselAnimating = false
            carouselDragOffset = 0
            // 更新调色板缓存
            updateCachedHeroPalette()
            return
        }

        let targetIndex: Int
        if
            let currentHeroID,
            let existingIndex = wallpapers.firstIndex(where: { $0.id == currentHeroID })
        {
            targetIndex = existingIndex
        } else {
            targetIndex = 0
        }

        let displayIndex = carouselDisplayIndex(for: targetIndex, count: wallpapers.count)
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            currentCarouselIndex = targetIndex
            currentCarouselDisplayIndex = displayIndex
            currentHeroID = wallpapers[targetIndex].id
            isCarouselInteracting = false
            isCarouselAnimating = false
            carouselDragOffset = 0
        }
        
        // 更新调色板缓存
        updateCachedHeroPalette()
    }

    private func selectHero(at index: Int, animated: Bool = true) {
        let wallpapers = heroWallpapers
        guard wallpapers.indices.contains(index) else { return }
        moveCarousel(toDisplayIndex: carouselDisplayIndex(for: index, count: wallpapers.count), animated: animated)
    }

    private func startCarouselAutoPlay() {
        guard timerManager.timer == nil, heroWallpapers.count > 1 else { return }

        Task { @MainActor in
            timerManager.timer = Timer.scheduledTimer(withTimeInterval: carouselAutoPlayInterval, repeats: true) { _ in
                Task { @MainActor in
                    guard !isCarouselInteracting, !isCarouselAnimating, heroWallpapers.count > 1 else { return }
                    showNextHero()
                }
            }
        }
    }

    private func stopCarouselAutoPlay() {
        timerManager.timer?.invalidate()
        timerManager.timer = nil
    }

    private func showPreviousHero() {
        advanceCarousel(by: -1)
    }

    private func showNextHero() {
        advanceCarousel(by: 1)
    }

    private func advanceCarousel(by step: Int, animated: Bool = true) {
        let count = heroWallpapers.count
        guard count > 1, !isCarouselAnimating else { return }
        moveCarousel(toDisplayIndex: currentCarouselDisplayIndex + step, animated: animated)
    }

    private func carouselDisplayIndex(for actualIndex: Int, count: Int) -> Int {
        guard count > 1 else { return max(actualIndex, 0) }
        return actualIndex + 1
    }

    private func actualCarouselIndex(for displayIndex: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }

        switch displayIndex {
        case 0:
            return count - 1
        case count + 1:
            return 0
        default:
            return min(max(displayIndex - 1, 0), count - 1)
        }
    }

    private func moveCarousel(toDisplayIndex targetDisplayIndex: Int, animated: Bool = true) {
        let wallpapers = heroWallpapers
        guard !wallpapers.isEmpty else { return }

        let maxDisplayIndex = wallpapers.count > 1 ? wallpapers.count + 1 : 0
        let boundedDisplayIndex = min(max(targetDisplayIndex, 0), maxDisplayIndex)
        let resolvedIndex = actualCarouselIndex(for: boundedDisplayIndex, count: wallpapers.count)
        let resolvedHeroID = wallpapers[resolvedIndex].id

        cancelCarouselLoopReset()

        let update = {
            currentCarouselDisplayIndex = boundedDisplayIndex
            currentCarouselIndex = resolvedIndex
            currentHeroID = resolvedHeroID
            carouselDragOffset = 0
        }

        if animated {
            isCarouselAnimating = true
            withAnimation(.easeInOut(duration: carouselPageSnapDuration)) {
                update()
            }
            scheduleCarouselLoopReset(for: boundedDisplayIndex, count: wallpapers.count)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                update()
            }
            completeCarouselLoopResetIfNeeded(for: boundedDisplayIndex, count: wallpapers.count)
        }
    }

    private func scheduleCarouselLoopReset(for displayIndex: Int, count: Int) {
        let workItem = DispatchWorkItem {
            completeCarouselLoopResetIfNeeded(for: displayIndex, count: count)
        }
        timerManager.loopResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + carouselPageSnapDuration, execute: workItem)
    }

    private func completeCarouselLoopResetIfNeeded(for displayIndex: Int, count: Int) {
        cancelCarouselLoopReset()

        guard count > 1 else {
            isCarouselAnimating = false
            return
        }

        let wrappedDisplayIndex: Int?
        switch displayIndex {
        case 0:
            wrappedDisplayIndex = count
        case count + 1:
            wrappedDisplayIndex = 1
        default:
            wrappedDisplayIndex = nil
        }

        if let wrappedDisplayIndex {
            let resolvedIndex = actualCarouselIndex(for: wrappedDisplayIndex, count: count)
            var transaction = Transaction()
            transaction.disablesAnimations = true

            withTransaction(transaction) {
                currentCarouselDisplayIndex = wrappedDisplayIndex
                currentCarouselIndex = resolvedIndex
                currentHeroID = heroWallpapers[resolvedIndex].id
                carouselDragOffset = 0
            }
        }

        isCarouselAnimating = false
    }

    private func cancelCarouselLoopReset() {
        timerManager.loopResetWorkItem?.cancel()
        timerManager.loopResetWorkItem = nil
    }

    private func scheduleCarouselInteractionReset(after delay: TimeInterval) {
        cancelCarouselInteractionReset()

        let workItem = DispatchWorkItem {
            isCarouselInteracting = false
            startCarouselAutoPlay()
        }

        timerManager.interactionResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelCarouselInteractionReset() {
        timerManager.interactionResetWorkItem?.cancel()
        timerManager.interactionResetWorkItem = nil
    }

    private func heroCarouselDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard heroWallpapers.count > 1, !isCarouselAnimating else { return }

                let horizontalTranslation = value.translation.width
                let verticalTranslation = value.translation.height
                guard abs(horizontalTranslation) > abs(verticalTranslation) else { return }

                if !isCarouselInteracting {
                    cancelCarouselInteractionReset()
                    isCarouselInteracting = true
                    stopCarouselAutoPlay()
                }

                carouselDragOffset = horizontalTranslation
            }
            .onEnded { value in
                guard heroWallpapers.count > 1 else { return }

                let horizontalTranslation = value.translation.width
                let verticalTranslation = value.translation.height
                let isHorizontalDrag = abs(horizontalTranslation) > abs(verticalTranslation)

                guard isHorizontalDrag else {
                    carouselDragOffset = 0
                    scheduleCarouselInteractionReset(after: 0.08)
                    return
                }

                let predictedTranslation = value.predictedEndTranslation.width
                let resolvedTranslation = abs(predictedTranslation) > abs(horizontalTranslation)
                    ? predictedTranslation
                    : horizontalTranslation
                let threshold = width * carouselDragThresholdRatio

                if resolvedTranslation <= -threshold {
                    advanceCarousel(by: 1)
                } else if resolvedTranslation >= threshold {
                    advanceCarousel(by: -1)
                } else {
                    withAnimation(.easeInOut(duration: carouselPageSnapDuration)) {
                        carouselDragOffset = 0
                    }
                }

                scheduleCarouselInteractionReset(after: carouselPageSnapDuration + 0.08)
            }
    }
}

private struct HeroWallpaperImageSlide: View {
    let wallpaper: Wallpaper
    let isCurrent: Bool
    
    private var palette: HeroDrivenPalette {
        HeroDrivenPalette(wallpaper: wallpaper)
    }
    
    private var imageURL: URL? {
        wallpaper.fullImageURL ?? wallpaper.thumbURL
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            KFImage(imageURL)
                .fade(duration: 0.3)
                .placeholder { _ in
                    heroPlaceholder(size: size, showsProgress: true)
                }
                .resizable()
                .scaledToFill()
                .scaleEffect(isCurrent ? 1.0 : 1.015)
        }
        .clipped()
    }
    
    private func heroLoadedContent(image: Image, size: CGSize) -> some View {
        ZStack {
            heroBackdrop(image: image, size: size)
            heroLightOverlay
        }
    }
    
    private func heroBackdrop(image: Image, size: CGSize) -> some View {
        ZStack {
            // 备用背景色，防止图片加载前或加载失败时显示黑色
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            palette.backdropTop,
                            palette.backdropMid,
                            Color(hex: "1a1a2e")
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width * 1.2, height: size.height * 1.2)
                .position(x: size.width / 2, y: size.height / 2)
                .clipped()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.primary.opacity(0.22),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size.width * 0.42
                    )
                )
                .frame(width: size.width * 0.72, height: size.width * 0.72)
                .blur(radius: 54)
                .offset(x: -size.width * 0.18, y: -size.height * 0.22)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.secondary.opacity(0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size.width * 0.46
                    )
                )
                .frame(width: size.width * 0.78, height: size.width * 0.78)
                .blur(radius: 60)
                .offset(x: size.width * 0.2, y: -size.height * 0.08)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            palette.heroCanvasTop.opacity(0.05),
                            palette.heroCanvasMid.opacity(0.03),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.02),
                            Color.clear,
                            Color.black.opacity(0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
    
    private func heroPlaceholder(size: CGSize, showsProgress: Bool) -> some View {
        ZStack {
            // 使用更亮的默认颜色，避免显示黑色
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "2a2a4a"),
                            Color(hex: "1a1a2e"),
                            Color(hex: "0f0f1a")
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Rectangle()
                .fill(.regularMaterial)
                .opacity(0.15)

            Group {
                if showsProgress {
                    CustomProgressView(tint: .white)
                } else {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(heroLightOverlay)
    }
    
    private var heroLightOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.1),
                    Color.black.opacity(0.48)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.32),
                    Color.clear,
                    Color.black.opacity(0.14)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            RadialGradient(
                colors: [
                    Color.clear,
                    Color.clear,
                    Color.black.opacity(0.26)
                ],
                center: .bottomLeading,
                startRadius: 40,
                endRadius: 520
            )
        }
    }
}

private struct HeroCaptionPanel: View {
    let wallpaper: Wallpaper
    let isFavorite: Bool
    let onOpen: () -> Void
    let onFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(heroEyebrow)
                .font(.system(size: 13, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.72))

            Text(heroTitle)
                .font(.system(size: 46, weight: .bold, design: .serif))
                .foregroundStyle(.white)
                .lineLimit(2)

            HeroMetaLine(items: heroMetadata)

            HStack(spacing: 12) {
                HeroActionButton(
                    title: t("viewWallpaper"),
                    systemImage: "play.fill",
                    prominence: .primary,
                    action: onOpen
                )

                HeroActionButton(
                    title: "\(wallpaper.favorites)",
                    systemImage: isFavorite ? "heart.fill" : "heart",
                    iconColor: isFavorite ? Color(hex: "FF5A7D") : nil,
                    prominence: .secondary,
                    action: onFavorite
                )
            }
            .glassContainer(spacing: 12)
        }
    }

    private var heroTitle: String {
        if let primary = wallpaper.tags?.first(where: { !$0.name.isEmpty })?.name {
            return beautifyTitle(primary)
        }
        if let secondary = wallpaper.tags?.dropFirst().first(where: { !$0.name.isEmpty })?.name {
            return beautifyTitle(secondary)
        }
        return "Wallhaven \(wallpaper.id)"
    }

    private var heroEyebrow: String {
        if let tag = wallpaper.tags?.first(where: { !$0.name.isEmpty })?.name {
            return beautifyTitle(tag).uppercased()
        }
        return categoryDisplayName.uppercased()
    }

    private var heroMetadata: [String] {
        [
            wallpaper.resolution,
            categoryDisplayName,
            fileSizeText,
            fileTypeText
        ]
        .filter { !$0.isEmpty }
    }

    private var categoryDisplayName: String {
        switch wallpaper.category.lowercased() {
        case "general":
            return t("featured")
        case "anime":
            return t("filter.anime")
        case "people":
            return t("filter.people")
        default:
            return wallpaper.category.capitalized
        }
    }

    private var fileSizeText: String {
        guard let fileSize = wallpaper.fileSize else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }

    private var fileTypeText: String {
        guard let fileType = wallpaper.fileType, !fileType.isEmpty else { return "" }
        return fileType.replacingOccurrences(of: "image/", with: "").uppercased()
    }

    private func beautifyTitle(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { chunk in
                let word = String(chunk)
                if word.count <= 3 {
                    return word.uppercased()
                }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}

private struct HeroMetaLine: View {
    let items: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    metaLabel(text: item, isLast: index == items.count - 1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(Array(items.prefix(2).enumerated()), id: \.offset) { index, item in
                        metaLabel(text: item, isLast: index == min(items.prefix(2).count - 1, 1))
                    }
                }

                HStack(spacing: 8) {
                    ForEach(Array(items.dropFirst(2).enumerated()), id: \.offset) { index, item in
                        metaLabel(text: item, isLast: index == items.dropFirst(2).count - 1)
                    }
                }
            }
        }
    }

    private func metaLabel(text: String, isLast: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)

            if !isLast {
                Circle()
                    .fill(Color.white.opacity(0.26))
                    .frame(width: 3.5, height: 3.5)
            }
        }
    }
}

private struct HeroActionButton: View {
    enum Prominence {
        case primary
        case secondary
    }

    let title: String
    let systemImage: String
    var iconColor: Color?
    let prominence: Prominence
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor ?? .white)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .liquidGlassSurface(
                prominence == .primary ? .prominent : .regular,
                tint: prominence == .primary ? LiquidGlassColors.primaryPink.opacity(0.16) : nil,
                in: Capsule(style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
    }
}

private struct HeroPaginationDots: View {
    let count: Int
    let currentIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == currentIndex ? Color.white : Color.white.opacity(0.32))
                    .frame(width: index == currentIndex ? 9 : 7, height: index == currentIndex ? 9 : 7)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(index)
                    }
            }
        }
    }
}

private struct HomeShelfSection: View {
    let title: String
    let wallpapers: [Wallpaper]
    let onSelect: (Wallpaper) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.54))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    )

                Spacer()
            }

            if wallpapers.isEmpty {
                HorizontalScrollSkeleton()
                    .frame(height: 158)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(Array(wallpapers.enumerated()), id: \.element.id) { index, wallpaper in
                            HomeShelfCard(
                                wallpaper: wallpaper,
                                onTap: { onSelect(wallpaper) }
                            )
                            .onAppear {
                                let urls = (index + 1..<(index + 4))
                                    .filter { $0 < wallpapers.count }
                                    .compactMap { wallpapers[$0].thumbURL }
                                ImagePrefetcher(urls: urls).start()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

struct HomeShelfCard: View {
    let wallpaper: Wallpaper
    let onTap: () -> Void

    @State private var isHovered = false

    private let cardSize = CGSize(width: 278, height: 158)

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                KFImage(wallpaper.thumbURL)
                    .fade(duration: 0.3)
                    .placeholder { _ in
                        SkeletonCard(width: cardSize.width, height: cardSize.height, cornerRadius: 18)
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                .frame(width: cardSize.width, height: cardSize.height)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        tagChip(text: wallpaper.categoryDisplayName)
                        tagChip(text: wallpaper.purityDisplayName)
                    }

                    if let primaryColorHex = wallpaper.primaryColorHex {
                        colorChip(hex: primaryColorHex)
                    }
                }
                .padding(12)

                VStack {
                    Spacer()

                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(wallpaper.primaryTagName ?? wallpaper.categoryDisplayName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.94))
                                .lineLimit(1)

                            Text(wallpaper.resolution)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            statLabel(systemImage: "heart.fill", value: compactNumber(wallpaper.favorites), tint: Color(hex: "FF5A7D"))
                            statLabel(systemImage: "eye.fill", value: compactNumber(wallpaper.views), tint: .white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(0.28),
                                Color.black.opacity(0.7)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.22 : 0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.3 : 0.16), radius: isHovered ? 18 : 10, y: isHovered ? 12 : 6)
            .scaleEffect(isHovered ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                isHovered = hovering
            }
        }
        .drawingGroup(opaque: false, colorMode: .linear)
    }

    private func tagChip(text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.34))
            .clipShape(Capsule())
    }

    private func colorChip(hex: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: "#\(hex)"))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.5)
                )

            Text("#\(hex)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.34))
        .clipShape(Capsule())
    }

    private func statLabel(systemImage: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(tint)
    }

    private func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

private struct HeroEdgeButton: View {
    enum Direction {
        case previous
        case next

        var iconName: String {
            switch self {
            case .previous:
                return "chevron.left"
            case .next:
                return "chevron.right"
            }
        }
    }

    let direction: Direction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction.iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 46, height: 46)
                .liquidGlassSurface(.regular, tint: LiquidGlassColors.glassTint, in: Circle())
                .padding(10) // 扩大点击热区，修复按钮边缘及旁边区域无法点击的问题
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}

private struct HomeShelfDeckBackground: View {
    let palette: HeroDrivenPalette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)

        ZStack {
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            palette.surfaceTop,
                            palette.surfaceMid,
                            palette.surfaceBottom
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            shape
                .fill(.ultraThinMaterial)
                .opacity(0.72)

            shape
                .fill(
                    RadialGradient(
                        colors: [
                            palette.primary.opacity(0.28),
                            .clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 360
                    )
                )

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}

// MARK: - 首页媒体区域（动态壁纸）
private struct HomeMediaSection: View {
    let title: String
    let mediaItems: [MediaItem]
    let onSelect: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.54))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    )

                Spacer()
            }

            if mediaItems.isEmpty {
                HorizontalScrollSkeleton()
                    .frame(height: 158)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, item in
                            HomeMediaCard(
                                item: item,
                                onTap: { onSelect(item) }
                            )
                            .onAppear {
                                let urls = (index + 1..<(index + 4))
                                    .filter { $0 < mediaItems.count }
                                    .map { mediaItems[$0].thumbnailURL }
                                ImagePrefetcher(urls: urls).start()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct HomeMediaCard: View {
    let item: MediaItem
    let onTap: () -> Void

    @State private var isHovered = false

    private let cardSize = CGSize(width: 278, height: 158)

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // 背景图
                KFImage(item.thumbnailURL)
                    .fade(duration: 0.3)
                    .placeholder { _ in
                        SkeletonCard(width: cardSize.width, height: cardSize.height, cornerRadius: 18)
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)

                // 渐变遮罩
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.1),
                        Color.black.opacity(0.4)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )

                // 顶部标签
                VStack {
                    HStack {
                        Text(t("aspect.dynamic"))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(hex: "20C1FF").opacity(0.7))
                            )

                        Spacer()

                        Text(item.resolutionLabel)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.black.opacity(0.4))
                            )
                    }
                    .padding(12)

                    Spacer()
                }
            }
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.22 : 0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovered ? 0.3 : 0.16), radius: isHovered ? 18 : 10, y: isHovered ? 12 : 6)
            .scaleEffect(isHovered ? 1.015 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                isHovered = hovering
            }
        }
        .drawingGroup(opaque: false, colorMode: .linear)
    }
}

