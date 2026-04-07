import SwiftUI

// MARK: - macOS 风格设置表单组件（深色主题）

/// 设置表单容器 - 深色背景（Arc风格）
struct MacSettingsForm<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color(hex: "1C1C1E"))
    }
}

/// macOS 风格设置分组卡片 - Arc风格
struct MacSettingsSection<Content: View>: View {
    let header: String?
    let footer: String?
    let content: Content
    
    init(
        header: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.footer = footer
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: "2C2C2E"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

/// macOS 风格设置项 - Arc风格（带图标和绿色开关）
struct MacSettingsRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let showDivider: Bool
    
    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String? = nil,
        showDivider: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.showDivider = showDivider
        self.trailing = trailing()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // 图标 - 圆角矩形，Arc风格
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconColor)
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                }
                
                // 标题和副标题
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.9))
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                
                Spacer()
                
                // 右侧控件
                trailing
                    .frame(alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            
            if showDivider {
                Divider()
                    .background(Color.white.opacity(0.08))
                    .padding(.leading, 58)
            }
        }
    }
}

/// macOS 风格开关 - Arc风格（绿色）
struct MacToggle: View {
    @Binding var isOn: Bool
    
    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(ArcToggleStyle())
    }
}

/// Arc风格绿色开关
struct ArcToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(configuration.isOn ? Color(hex: "30D158") : Color(hex: "3A3A3C"))
                .frame(width: 40, height: 24)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                        .offset(x: configuration.isOn ? 8 : -8)
                        .animation(.easeOut(duration: 0.2), value: configuration.isOn)
                )
        }
        .buttonStyle(.plain)
    }
}

/// macOS 风格选择器行（深色）
struct MacSettingsPickerRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var selection: String
    let options: [String]
    let optionLabels: [String: String]
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(iconColor)
                    .frame(width: 32, height: 32)
                
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
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
                HStack(spacing: 4) {
                    Text(optionLabels[selection] ?? selection)
                        .font(.system(size: 13))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                )
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
