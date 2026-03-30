import SwiftUI

// MARK: - 筛选视图 - Liquid Glass 胶囊风格
struct FilterView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showProtectedPurityAlert = false

    // 预定义分辨率选项
    private let resolutionOptions = [
        "1920x1080", "2560x1440", "3840x2160", "1280x720",
        "1600x900", "1366x768", "1440x900", "1680x1050"
    ]

    // 预定义比例选项
    private let ratioOptions = [
        "16x9", "16x10", "21x9", "4x3", "3x2", "1x1", "9x16", "10x16"
    ]

    // 预定义颜色选项
    private struct ColorOption: Identifiable {
        let id = UUID()
        let apiValue: String
        let key: String
        let fallbackName: String
        var name: String {
            let localized = t("color.\(key)")
            return localized == "color.\(key)" ? fallbackName : localized
        }
        var displayHex: String { "#\(apiValue)" }
    }

    private let colorOptions: [ColorOption] = WallhavenAPI.officialColorPalette.map { preset in
        let fallbackKey = preset.displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        let mappedKey: String = switch preset.hex.lowercased() {
        case "990000": "red"
        case "336600": "green"
        case "0066cc": "blue"
        case "999900": "yellow"
        case "993399": "purple"
        case "66cccc": "teal"
        case "ff6600": "orange"
        case "663399": "violet"
        case "0099cc": "skyblue"
        case "999999": "gray"
        case "000000": "black"
        case "ffffff": "white"
        default: fallbackKey
        }

        return ColorOption(apiValue: preset.hex, key: mappedKey, fallbackName: preset.displayName)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            topBar

            // 筛选内容
            ScrollView {
                VStack(spacing: 16) {
                    // 分类筛选
                    categorySection

                    // 纯度筛选
                    puritySection

                    // 排序选项
                    sortingSection

                    // 分辨率筛选
                    resolutionSection

                    // 比例筛选
                    ratioSection

                    // 颜色筛选
                    colorSection
                }
                .padding(20)
            }
            .background(Color.clear)

            // 底部按钮
            bottomBar
        }
        .background(
            ZStack {
                LiquidGlassAtmosphereBackground(
                    primary: LiquidGlassColors.secondaryViolet,
                    secondary: LiquidGlassColors.primaryPink,
                    tertiary: LiquidGlassColors.accentCyan,
                    baseTop: LiquidGlassColors.midBackground,
                    baseBottom: LiquidGlassColors.deepBackground
                )

                // 颗粒材质覆盖层
                GrainTextureOverlay()
            }
        )
        .alert(t("apiKeyRequired"), isPresented: $showProtectedPurityAlert) {
            Button(t("ok"), role: .cancel) {}
        } message: {
            Text(t("apiKeyNeeded"))
        }
    }

    // MARK: - 顶部栏
    private var topBar: some View {
        HStack {
            Text(t("filters"))
                .font(.system(size: 14, weight: .bold))
                .tracking(2)
                .foregroundColor(LiquidGlassColors.textPrimary)

            Spacer()

            // 重置按钮
            LiquidGlassPillButton(
                title: t("reset.all"),
                icon: "arrow.counterclockwise",
                isSelected: false,
                color: LiquidGlassColors.secondaryViolet
            ) {
                resetFilters()
            }
            .padding(.trailing, 8)

            // 关闭按钮
            LiquidGlassFloatingButton(
                icon: "xmark",
                color: LiquidGlassColors.textSecondary,
                size: 36
            ) {
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .liquidGlassCard()
    }

    // MARK: - 分类筛选
    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t("categories"))

            HStack(spacing: 12) {
                LiquidGlassPillButton(
                    title: t("general"),
                    icon: "square.grid.2x2",
                    isSelected: viewModel.categoryGeneral,
                    color: LiquidGlassColors.secondaryViolet
                ) {
                    viewModel.categoryGeneral.toggle()
                }

                LiquidGlassPillButton(
                    title: t("anime"),
                    icon: "sparkles",
                    isSelected: viewModel.categoryAnime,
                    color: LiquidGlassColors.primaryPink
                ) {
                    viewModel.categoryAnime.toggle()
                }

                LiquidGlassPillButton(
                    title: t("people"),
                    icon: "person.fill",
                    isSelected: viewModel.categoryPeople,
                    color: LiquidGlassColors.warningOrange
                ) {
                    viewModel.categoryPeople.toggle()
                }
            }
        }
        .liquidGlassCard()
    }

    // MARK: - 纯度筛选 - 苹果标签栏风格
    private var puritySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t("purity"))

            // 苹果风格标签栏
            HStack(spacing: 0) {
                // SFW 标签
                LiquidGlassPillButton(
                    title: "SFW",
                    icon: "checkmark.shield.fill",
                    isSelected: viewModel.puritySFW,
                    color: LiquidGlassColors.onlineGreen
                ) {
                    viewModel.puritySFW.toggle()
                }

                // 分隔线
                Rectangle()
                    .fill(LiquidGlassColors.glassBorder)
                    .frame(width: 1, height: 24)

                // Sketchy 标签
                LiquidGlassPillButton(
                    title: "Sketchy",
                    icon: "exclamationmark.shield.fill",
                    isSelected: viewModel.puritySketchy,
                    color: LiquidGlassColors.warningOrange
                ) {
                    toggleProtectedPurity(for: \.puritySketchy)
                }

                // 分隔线
                Rectangle()
                    .fill(LiquidGlassColors.glassBorder)
                    .frame(width: 1, height: 24)

                // NSFW 标签
                LiquidGlassPillButton(
                    title: "NSFW",
                    icon: "xmark.shield.fill",
                    isSelected: viewModel.purityNSFW,
                    color: LiquidGlassColors.primaryPink
                ) {
                    toggleProtectedPurity(for: \.purityNSFW)
                }
            }
            .padding(4)
            .background(LiquidGlassColors.glassWhiteSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !viewModel.apiKeyConfigured {
                Text(t("sketchyNsfwRequire"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(LiquidGlassColors.textSecondary)
            }
        }
        .liquidGlassCard()
    }

    // MARK: - 排序选项
    private var sortingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t("sorting"))

            VStack(spacing: 12) {
                // 排序方式
                HStack(spacing: 12) {
                    ForEach([
                        ("date", t("date")),
                        ("views", t("views")),
                        ("favorites", t("favorites")),
                        ("toplist", t("toplist")),
                        ("random", t("random"))
                    ], id: \.0) { key, name in
                        LiquidGlassPillButton(
                            title: name,
                            icon: iconForSortOption(key),
                            isSelected: sortingOptionKey == key,
                            color: optionColor(for: sortingOptionFromKey(key))
                        ) {
                            viewModel.sortingOption = sortingOptionFromKey(key)
                        }
                    }
                }

                // 排序顺序
                HStack(spacing: 12) {
                    LiquidGlassPillButton(
                        title: t("descending"),
                        icon: "arrow.down",
                        isSelected: viewModel.orderDescending,
                        color: LiquidGlassColors.secondaryViolet
                    ) {
                        viewModel.orderDescending = true
                    }

                    LiquidGlassPillButton(
                        title: t("ascending"),
                        icon: "arrow.up",
                        isSelected: !viewModel.orderDescending,
                        color: LiquidGlassColors.secondaryViolet
                    ) {
                        viewModel.orderDescending = false
                    }
                }

                // TopRange (仅当选择 toplist 时显示)
                if viewModel.sortingOption == .toplist {
                    HStack(spacing: 8) {
                        Text(t("top.range"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(LiquidGlassColors.textSecondary)

                        ForEach([
                            ("1D", TopRange.oneDay),
                            ("3D", TopRange.threeDays),
                            ("1W", TopRange.oneWeek),
                            ("1M", TopRange.oneMonth),
                            ("3M", TopRange.threeMonths),
                            ("6M", TopRange.sixMonths),
                            ("1Y", TopRange.oneYear)
                        ], id: \.1.rawValue) { name, range in
                            LiquidGlassPillButton(
                                title: name,
                                icon: nil,
                                isSelected: viewModel.topRange == range,
                                color: LiquidGlassColors.secondaryViolet
                            ) {
                                viewModel.topRange = range
                            }
                        }
                    }
                }
            }
        }
        .liquidGlassCard()
    }

    // MARK: - 分辨率筛选
    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t("resolutions"))

            FlowLayout(spacing: 8) {
                ForEach(resolutionOptions, id: \.self) { resolution in
                    let isSelected = viewModel.selectedResolutions.contains(resolution)
                    LiquidGlassPillButton(
                        title: resolution,
                        icon: nil,
                        isSelected: isSelected,
                        color: LiquidGlassColors.primaryPink
                    ) {
                        if isSelected {
                            viewModel.selectedResolutions.removeAll { $0 == resolution }
                        } else {
                            viewModel.selectedResolutions.append(resolution)
                        }
                    }
                }
            }
        }
        .liquidGlassCard()
    }

    // MARK: - 比例筛选
    private var ratioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t("ratios"))

            FlowLayout(spacing: 8) {
                ForEach(ratioOptions, id: \.self) { ratio in
                    let isSelected = viewModel.selectedRatios.contains(ratio)
                    LiquidGlassPillButton(
                        title: displayRatio(ratio),
                        icon: nil,
                        isSelected: isSelected,
                        color: LiquidGlassColors.primaryPink
                    ) {
                        if isSelected {
                            viewModel.selectedRatios.removeAll { $0 == ratio }
                        } else {
                            viewModel.selectedRatios.append(ratio)
                        }
                    }
                }
            }
        }
        .liquidGlassCard()
    }

    // MARK: - 颜色筛选
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(t("colors"))

            FlowLayout(spacing: 8) {
                ForEach(colorOptions) { option in
                    let isSelected = viewModel.selectedColors.contains(option.apiValue)
                    LiquidGlassPillButton(
                        title: option.name,
                        icon: nil,
                        isSelected: isSelected,
                        color: Color(hex: option.displayHex)
                    ) {
                        if isSelected {
                            viewModel.selectedColors = []
                        } else {
                            viewModel.selectedColors = [option.apiValue]
                        }
                    }
                }
            }
        }
        .liquidGlassCard()
    }

    // MARK: - 底部按钮
    private var bottomBar: some View {
        HStack(spacing: 16) {
            // 取消按钮
            LiquidGlassPillButton(
                title: t("cancel"),
                icon: "xmark",
                isSelected: false,
                color: LiquidGlassColors.textSecondary
            ) {
                dismiss()
            }

            // 应用按钮
            LiquidGlassPillButton(
                title: t("apply.filters"),
                icon: "checkmark",
                isSelected: true,
                color: LiquidGlassColors.onlineGreen
            ) {
                Task {
                    await viewModel.search()
                }
                dismiss()
            }
        }
        .padding(20)
        .liquidGlassCard()
        .overlay(
            Rectangle()
                .fill(LiquidGlassColors.glassBorder)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }

    // MARK: - 辅助方法
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(2)
            .foregroundColor(LiquidGlassColors.textSecondary)
    }

    private func optionColor(for option: SortingOption) -> Color {
        switch option {
        case .dateAdded: return LiquidGlassColors.secondaryViolet
        case .views: return LiquidGlassColors.onlineGreen
        case .favorites: return LiquidGlassColors.primaryPink
        case .toplist: return LiquidGlassColors.warningOrange
        case .random: return LiquidGlassColors.secondaryViolet
        case .relevance: return LiquidGlassColors.secondaryViolet
        }
    }

    private func iconForSortOption(_ key: String) -> String {
        switch key {
        case "date": return "calendar"
        case "views": return "eye"
        case "favorites": return "heart.fill"
        case "toplist": return "chart.line.uptrend.xyaxis"
        case "random": return "shuffle"
        case "hot": return "flame.fill"
        default: return "calendar"
        }
    }

    private var sortingOptionKey: String {
        switch viewModel.sortingOption {
        case .dateAdded: return "date"
        case .views: return "views"
        case .favorites: return "favorites"
        case .toplist: return "toplist"
        case .random: return "random"
        case .relevance: return "relevance"
        }
    }

    private func sortingOptionFromKey(_ key: String) -> SortingOption {
        switch key {
        case "date": return .dateAdded
        case "views": return .views
        case "favorites": return .favorites
        case "toplist": return .toplist
        case "random": return .random
        case "relevance": return .relevance
        default: return .dateAdded
        }
    }

    private func displayRatio(_ ratio: String) -> String {
        ratio.replacingOccurrences(of: "x", with: ":")
    }

    private func toggleProtectedPurity(for keyPath: ReferenceWritableKeyPath<WallpaperViewModel, Bool>) {
        guard viewModel.apiKeyConfigured else {
            showProtectedPurityAlert = true
            return
        }

        viewModel[keyPath: keyPath].toggle()
    }

    private func resetFilters() {
        viewModel.categoryGeneral = true
        viewModel.categoryAnime = true
        viewModel.categoryPeople = true
        viewModel.puritySFW = true
        viewModel.puritySketchy = false
        viewModel.purityNSFW = false
        viewModel.sortingOption = .dateAdded
        viewModel.orderDescending = true
        viewModel.topRange = .oneMonth
        viewModel.selectedResolutions = []
        viewModel.selectedRatios = []
        viewModel.selectedColors = []
    }
}
