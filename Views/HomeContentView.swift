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
    /// 为 false 时不挂载重 UI（非当前 Tab），避免五 Tab 同时跑 ScrollView/轮播
    var isTabActive: Bool = true

    @State private var currentCarouselIndex = 0
    @State private var currentCarouselDisplayIndex = 0
    @State private var currentHeroID: String?
    @StateObject private var timerManager = CarouselTimerManager()
    @State private var isCarouselInteracting = false
    @State private var isCarouselAnimating = false
    @State private var carouselDragOffset: CGFloat = 0

    // 优化：缓存 heroPalette 避免每次访问都重新计算
    @State private var cachedHeroPalette: HeroDrivenPalette = HeroDrivenPalette(wallpaper: nil)

    // 首页背景氛围控制器
    @StateObject private var atmosphereController = HomeAtmosphereController()

    // 3:8 宽高比，按视口宽度自适应高度
    private func heroHeight(for width: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite, !width.isNaN, !width.isInfinite else { return 300 }
        return max(300, width * 0.375)
    }



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
        GeometryReader { containerProxy in
            let heroH = heroHeight(for: containerProxy.size.width)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroSection
                        .zIndex(1)
                        .frame(height: heroH)

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
            .scrollDisabled(!isTabActive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            homeBackground
                .ignoresSafeArea()
                .id(currentHeroID)
        )
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
            handleScroll(offset: offset)
        }
        .onAppear {
            syncCarouselState(with: heroWallpapers)
            if isTabActive {
                startCarouselAutoPlay()
            }

            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await mediaViewModel.initialLoadIfNeeded()
                await mediaViewModel.refreshHomeItems()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperDataSourceChanged)) { _ in
            Task { @MainActor in
                await viewModel.refresh()
            }
        }
        .onChange(of: isTabActive) { _, active in
            if active {
                syncCarouselState(with: heroWallpapers)
                startCarouselAutoPlay()
            } else {
                stopCarouselAutoPlay()
                cancelCarouselLoopReset()
                cancelCarouselInteractionReset()
            }
        }
        .onChange(of: heroWallpaperIDs) { _, _ in
            guard isTabActive else { return }
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
        let wallpapers = heroWallpapers
        
        return GeometryReader { geometry in
            let width = geometry.size.width
            let height = heroHeight(for: width)
            
            ZStack {
                if wallpapers.isEmpty {
                    HeroSkeletonView(height: height)
                } else {
                    heroCarousel(width: width, height: height, wallpapers: wallpapers)

                    if let wallpaper = currentHeroWallpaper {
                        HeroCaptionPanel(
                            wallpaper: wallpaper,
                            isFavorite: viewModel.isFavorite(wallpaper),
                            onOpen: { selectedWallpaper = wallpaper },
                            onFavorite: { viewModel.toggleFavorite(wallpaper) }
                        )
                        .frame(maxWidth: 520, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, 112)
                        .padding(.trailing, 96)
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
                    
                    // 底部渐变模糊层 - 让轮播图和背景自然融合
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(0.15),
                                Color.black.opacity(0.45)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 80)
                        .blur(radius: 20)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipped()
        }
    }

    private func heroCarousel(width: CGFloat, height: CGFloat, wallpapers: [Wallpaper]) -> some View {
        let displayWallpapers = carouselDisplayWallpapers(from: wallpapers)

        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(displayWallpapers.enumerated()), id: \.offset) { _, wallpaper in
                    HeroWallpaperImageSlide(
                        wallpaper: wallpaper,
                        isCurrent: wallpaper.id == currentHeroID
                    )
                    .frame(width: width, height: height)
                }
            }
            .offset(x: -CGFloat(currentCarouselDisplayIndex) * width + carouselDragOffset)
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            heroCarouselDragGesture(width: width)
        )
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 38) {
            // 热门动态壁纸（使用独立的首页数据，不跟随 Explore 列表变化）
            HomeMediaSection(
                title: t("hotDynamic"),
                mediaItems: mediaViewModel.homeItems,
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
    }

    private var homeBackground: some View {
        let tint = ExploreAtmosphereTint.fromSampledTriplet(
            atmosphereController.primary,
            atmosphereController.secondary,
            atmosphereController.tertiary
        )
        return ExploreDynamicAtmosphereBackground(
            tint: tint,
            referenceImage: atmosphereController.referenceImage,
            lightweightBackdrop: false
        )
        .ignoresSafeArea()
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
            atmosphereController.resetToFallback()
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
            // 更新背景氛围色
            atmosphereController.updateWallpaper(wallpapers[targetIndex])
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
            // 更新背景氛围色
            atmosphereController.updateWallpaper(wallpapers[resolvedIndex])
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
                .setProcessor(DownsamplingImageProcessor(size: CGSize(width: size.width * 2, height: size.height * 2)))
                .cacheOriginalImage()
                .fade(duration: 0.25)
                .placeholder { _ in
                    heroPlaceholder(size: size, showsProgress: true)
                }
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }
    
    private func heroLoadedContent(image: Image, size: CGSize) -> some View {
        ZStack {
            heroBackdrop(image: image, size: size)
            heroLightOverlay
        }
    }
    
    private func heroBackdrop(image: Image, size: CGSize) -> some View {
        // 确保尺寸有效
        let safeWidth = max(1, size.width)
        let safeHeight = max(1, size.height)
        
        return ZStack {
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
                .frame(width: safeWidth * 1.2, height: safeHeight * 1.2)
                .position(x: safeWidth / 2, y: safeHeight / 2)
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
                        endRadius: max(1, safeWidth * 0.42)
                    )
                )
                .frame(width: max(1, safeWidth * 0.72), height: max(1, safeWidth * 0.72))
                .blur(radius: 54)
                .offset(x: -safeWidth * 0.18, y: -safeHeight * 0.22)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            palette.secondary.opacity(0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: max(1, safeWidth * 0.46)
                    )
                )
                .frame(width: max(1, safeWidth * 0.78), height: max(1, safeWidth * 0.78))
                .blur(radius: 60)
                .offset(x: safeWidth * 0.2, y: -safeHeight * 0.08)

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
        // 确保尺寸有效
        let safeWidth = max(1, size.width)
        let safeHeight = max(1, size.height)
        
        return ZStack {
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
        .frame(width: safeWidth, height: safeHeight)
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
                        ForEach(wallpapers) { wallpaper in
                            HomeShelfCard(
                                wallpaper: wallpaper,
                                onTap: { onSelect(wallpaper) }
                            )
                            .onAppear {
                                guard let index = wallpapers.firstIndex(where: { $0.id == wallpaper.id }) else { return }
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

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction.iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 0.98 : 0.88))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .liquidGlassSurface(
                    .max,
                    tint: Color.white.opacity(isHovered ? 0.22 : 0.12),
                    in: Circle()
                )
                .shadow(
                    color: Color.black.opacity(isHovered ? 0.38 : 0.22),
                    radius: isHovered ? 14 : 10,
                    y: isHovered ? 8 : 5
                )
        }
        .buttonStyle(HeroEdgePressButtonStyle())
        .frame(width: 66, height: 66)
        .contentShape(Circle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }
}

private struct HeroEdgePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
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
                        ForEach(mediaItems) { item in
                            HomeMediaCard(
                                item: item,
                                onTap: { onSelect(item) }
                            )
                            .onAppear {
                                guard let index = mediaItems.firstIndex(where: { $0.id == item.id }) else { return }
                                let urls = (index + 1..<(index + 4))
                                    .filter { $0 < mediaItems.count }
                                    .map { mediaItems[$0].coverImageURL }
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
                // 背景图（底层色块 + 失败占位由 KFMediaCoverImage 统一处理）
                KFMediaCoverImage(
                    url: item.coverImageURL,
                    animated: item.shouldRenderThumbnailAsAnimatedImage,
                    downsampleSize: CGSize(width: cardSize.width * 2, height: cardSize.height * 2),
                    fadeDuration: 0.3,
                    loadFinished: nil,
                    layoutSize: cardSize,
                    playAnimatedImage: true,
                    isVisible: true,
                    animateOnHoverOnly: true,
                    isHovered: isHovered
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
    }
}

// MARK: - 首页轮播背景氛围控制器

/// 从轮播图缩略图采样下半部分颜色，用于首页背景渐变
@MainActor
final class HomeAtmosphereController: ObservableObject {
    @Published private(set) var primary: Color = Color(hex: "5A7CFF")
    @Published private(set) var secondary: Color = Color(hex: "8A5CFF")
    @Published private(set) var tertiary: Color = Color(hex: "20C1FF")
    @Published private(set) var referenceImage: NSImage?

    private var loadTask: Task<Void, Never>?
    private var activeWallpaperID: String?

    static let fallback = HomeAtmosphereController()

    func updateWallpaper(_ wallpaper: Wallpaper?) {
        guard let wallpaper = wallpaper else {
            resetToFallback()
            return
        }

        let key = wallpaper.id
        if key == activeWallpaperID, referenceImage != nil {
            return
        }
        activeWallpaperID = key

        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil

        guard let url = wallpaper.thumbURL ?? wallpaper.smallThumbURL else { return }

        loadTask = Task {
            let result = try? await KingfisherManager.shared.retrieveImage(with: .network(url))
            guard !Task.isCancelled, let image = result?.image else { return }

            let processed = await Task.detached(priority: .userInitiated) {
                let small = image.constrainedForAtmosphereBackdrop()
                let sampledColors = ExploreImageColorSampler.triplet(from: small)
                return (small, sampledColors)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.referenceImage = processed.0
                if let (c1, c2, c3) = processed.1 {
                    withAnimation(.easeInOut(duration: 0.75)) {
                        self.primary = c1
                        self.secondary = c2
                        self.tertiary = c3
                    }
                }
            }
        }
    }

    func resetToFallback() {
        loadTask?.cancel()
        loadTask = nil
        referenceImage = nil
        activeWallpaperID = nil
        primary = Color(hex: "5A7CFF")
        secondary = Color(hex: "8A5CFF")
        tertiary = Color(hex: "20C1FF")
    }
}

