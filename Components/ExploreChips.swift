import SwiftUI

// MARK: - 通用分类芯片

public struct CategoryChip: View {
    let icon: String
    let title: String
    let accentColors: [String]
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    public init(
        icon: String,
        title: String,
        accentColors: [String],
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.accentColors = accentColors
        self.isSelected = isSelected
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: accentColors.map(Color.init(hex:)),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 22, height: 22)
                    
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSelected ? .white : .black.opacity(0.78))
                }
                
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.82))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                    if let accentColor = accentColors.first {
                        Capsule(style: .continuous)
                            .fill(Color(hex: accentColor).opacity(isSelected ? 0.15 : 0.08))
                    }
                }
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        (accentColors.first.map { Color(hex: $0) } ?? Color.white)
                            .opacity(isSelected ? 0.35 : 0.15),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 通用标签芯片

public struct TagChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.78))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(isSelected ? 0.3 : 0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .throttledHover(interval: 0.05) { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 探索页搜索栏

public struct ExploreSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let tint: Color
    let onSubmit: () -> Void
    let onClear: () -> Void
    
    public init(
        text: Binding<String>,
        placeholder: String,
        tint: Color,
        onSubmit: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) {
        self._text = text
        self.placeholder = placeholder
        self.tint = tint
        self.onSubmit = onSubmit
        self.onClear = onClear
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))
            
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .onSubmit(onSubmit)
            
            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.36))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 460)
        .frame(height: 46)
        .liquidGlassSurface(
            .prominent,
            tint: tint.opacity(0.1),
            in: Capsule(style: .continuous)
        )
    }
}

// MARK: - 重置按钮

public struct ResetFiltersButton: View {
    let tint: Color
    let action: () -> Void
    
    @State private var isHovered = false
    
    public init(tint: Color, action: @escaping () -> Void) {
        self.tint = tint
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .liquidGlassSurface(
                    .prominent,
                    tint: tint.opacity(0.12),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 排序菜单

public struct SortMenu<SortOption: SortOptionProtocol>: View {
    let options: [SortOption]
    @Binding var selected: SortOption
    let tint: Color
    
    public init(options: [SortOption], selected: Binding<SortOption>, tint: Color) {
        self.options = options
        self._selected = selected
        self.tint = tint
    }
    
    public var body: some View {
        Menu {
            ForEach(options) { option in
                Button(option.menuTitle) {
                    selected = option
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                Text(selected.title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .liquidGlassSurface(
                .regular,
                tint: tint.opacity(0.1),
                in: Capsule(style: .continuous)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Filter Chip

public struct FilterChip: View {
    public let title: String
    public let subtitle: String
    public let isSelected: Bool
    public let tint: Color
    public let action: () -> Void
    @State private var isHovered = false
    
    public init(title: String, subtitle: String = "", isSelected: Bool, tint: Color, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.tint = tint
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.94))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(isSelected ? 0.15 : 0.08))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(tint.opacity(isSelected ? 0.4 : 0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(AppFluidMotion.hoverEase, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 排序选项协议

public protocol SortOptionProtocol: Identifiable, Hashable {
    var title: String { get }
    var menuTitle: String { get }
}
