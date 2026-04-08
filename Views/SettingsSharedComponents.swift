import SwiftUI

// MARK: - 简洁设置组件（侧边栏导航风格）

/// 设置表单容器
struct MacSettingsForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }
}

/// 设置分组卡片
struct MacSettingsSection<Content: View>: View {
    let header: String?
    let content: Content

    init(
        header: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = header {
                Text(header)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .padding(.bottom, 10)
                    .padding(.leading, 2)
            }

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// 设置行 - 简洁无图标版本
struct MacSettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let showDivider: Bool

    init(
        title: String,
        subtitle: String? = nil,
        showDivider: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showDivider = showDivider
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            rowContent

            if showDivider {
                Divider()
                    .background(Color.white.opacity(0.06))
                    .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            trailing
                .frame(alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 开关控件
struct MacToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(CleanToggleStyle())
    }
}

/// 干净简洁的开关样式
struct CleanToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                // 轨道
                Capsule()
                    .fill(configuration.isOn
                          ? Color(hex: "30D158")
                          : Color.white.opacity(0.2))
                    .frame(width: 44, height: 24)

                // 滑块
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .offset(x: configuration.isOn ? 10 : -10)
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 46, height: 26)
    }
}

/// 信息行（标题 + 值）
struct MacInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 外部链接行
struct MacLinkRow: View {
    let title: String
    let action: (() -> Void)?

    init(title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button {
            action?()
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 以下保留供其他页面复用的旧组件

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
