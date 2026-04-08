import SwiftUI

// MARK: - macOS 精致设置表单组件（Apple 风格）

/// 设置表单容器 - 带微妙渐变背景
struct MacSettingsForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .background(
            // 微妙的径向渐变，增加深度感
            RadialGradient(
                colors: [
                    Color.white.opacity(0.03),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 100,
                endRadius: 400
            )
            .ignoresSafeArea()
        )
    }
}

/// 设置分组卡片 - Apple 精致毛玻璃风格
struct MacSettingsSection<Content: View>: View {
    let header: String?
    let footer: String?
    let icon: String?
    let iconTint: Color?
    let content: Content

    init(
        header: String? = nil,
        footer: String? = nil,
        icon: String? = nil,
        iconTint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.footer = footer
        self.icon = icon
        self.iconTint = iconTint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 分组头部
            if let header = header {
                sectionHeader(header, icon: icon, iconTint: iconTint)
            }

            // 内容卡片
            VStack(spacing: 0) {
                content
            }
            .background(settingsCardBackground)
            .overlay(settingsCardBorder)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(
                color: .black.opacity(0.08),
                radius: 8,
                x: 0,
                y: 2
            )

            // 分组底部说明
            if let footer = footer {
                Text(footer)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.top, 6)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: 分组标题
    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String?, iconTint: Color?) -> some View {
        HStack(spacing: 7) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconTint ?? LiquidGlassColors.secondaryViolet)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
                .tracking(width: 0.2)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.bottom, 8)
        .padding(.leading, 2)
    }

    // MARK: 卡片背景 - 多层渐变模拟毛玻璃
    private var settingsCardBackground: some View {
        ZStack {
            // 基础半透明层
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))

            // 顶部微妙高光
            RoundedRectangle(cornerRadius: 14, style: .continuous)
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

            // 内部微弱噪点纹理感（通过叠加实现）
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.01))
        }
    }

    // MARK: 卡片边框 - 渐变描边
    private var settingsCardBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.15),
                        Color.white.opacity(0.06),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )
    }
}

/// 设置行 - 精致的 Apple 风格行组件
struct MacSettingsRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let showDivider: Bool
    let action: (() -> Void)?

    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        showDivider: Bool = true,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.showDivider = showDivider
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let action = action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }

            if showDivider {
                Divider()
                    .background(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.04),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.leading, 58)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 13) {
            // 图标 - 柔和渐变圆形背景
            settingsIcon

            // 文字区域
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer()

            // 右侧控件
            trailing
                .frame(alignment: .trailing)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    // MARK: 精致图标
    private var settingsIcon: some View {
        ZStack {
            // 外圈光晕
            Circle()
                .fill(iconColor.opacity(0.15))
                .frame(width: 32, height: 32)

            // 渐变背景
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            iconColor.opacity(0.9),
                            iconColor.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 28, height: 28)

            // 高光
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.05)
                        ],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 14
                    )
                )
                .frame(width: 28, height: 28)

            // 图标
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0.5)
        }
    }
}

/// Apple 风格开关 - 带动画阴影
struct MacToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(AppleToggleStyle())
    }
}

/// Apple 精致开关样式
struct AppleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                // 外部阴影轨道
                Capsule()
                    .fill(configuration.isOn
                         ? Color.green.opacity(0.2)
                         : Color.white.opacity(0.12))
                    .frame(width: 48, height: 28)

                // 主轨道
                Capsule()
                    .fill(configuration.isOn
                         ? LinearGradient(
                             colors: [Color(hex: "34C759"), Color(hex: "30D158")],
                             startPoint: .leading,
                             endPoint: .trailing
                         )
                         : LinearGradient(
                             colors: [Color(hex: "787880"), Color(hex: "636366")],
                             startPoint: .leading,
                             endPoint: .trailing
                         ))
                    .frame(width: 47, height: 27)
                    .shadow(
                        color: configuration.isOn
                            ? Color.green.opacity(0.4)
                            : .black.opacity(0.15),
                        radius: configuration.isOn ? 4 : 2,
                        y: 1
                    )

                // 滑块
                Circle()
                    .fill(Color.white)
                    .frame(width: 23, height: 23)
                    .shadow(
                        color: .black.opacity(configuration.isOn ? 0.25 : 0.18),
                        radius: 3,
                        x: 0,
                        y: 1.5
                    )
                    .offset(x: configuration.isOn ? 10.5 : -10.5)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 51, height: 31)
    }
}

/// macOS 风格选择器行（精致版）
struct MacSettingsPickerRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var selection: String
    let options: [String]
    let optionLabels: [String: String]

    var body: some View {
        HStack(spacing: 13) {
            // 使用统一的图标样式
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 32, height: 32)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [iconColor.opacity(0.9), iconColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))

            Spacer()

            Menu {
                ForEach(options, id: \.self) { option in
                    Button(optionLabels[option] ?? option) {
                        selection = option
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(optionLabels[selection] ?? selection)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }
}

// MARK: - 设置页通用区块（供 SettingsView、DataSourceProfileEditorSheet 等复用）
struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let accentColor: Color
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        accentColor: Color = LiquidGlassColors.secondaryViolet,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 99, style: .continuous)
                        .fill(accentColor)
                        .frame(width: 26, height: 6)

                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                }
            }

            content
        }
    }
}

struct SettingsSurfaceCard<Content: View>: View {
    let padding: CGFloat
    let tint: Color?
    let content: Content

    init(
        padding: CGFloat = 20,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassSurface(
                .regular,
                tint: tint,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
    }
}

// MARK: - 设置页面容器

struct SettingsPage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LiquidGlassColors.deepBackground)
    }
}

@MainActor
func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    SettingsPage(content: content)
}

// MARK: - 设置状态标签

struct SettingsStatusBadge: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LiquidGlassColors.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}
