import SwiftUI

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
