import SwiftUI

// MARK: - 液态玻璃 Toggle
public struct LiquidGlassToggle: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var variant: GlassVariant = .regular
    var accentColor: Color = LiquidGlassColors.primaryPink
    
    @State private var isHovered = false
    
    public init(
        _ title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        variant: GlassVariant = .regular,
        accentColor: Color = LiquidGlassColors.primaryPink
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
        self.variant = variant
        self.accentColor = accentColor
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // 图标和文字
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isOn ? accentColor : LiquidGlassColors.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LiquidGlassColors.textPrimary)
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(LiquidGlassColors.textTertiary)
                    }
                }
            }
            
            Spacer()
            
            // 液态玻璃开关
            LiquidGlassSwitch(isOn: $isOn, accentColor: accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlassSurface(
            isHovered ? .prominent : .regular,
            tint: isOn ? accentColor.opacity(0.15) : nil,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 液态玻璃开关 (内部组件)
public struct LiquidGlassSwitch: View {
    @Binding var isOn: Bool
    var accentColor: Color = LiquidGlassColors.primaryPink
    
    @State private var isPressed = false
    
    public init(isOn: Binding<Bool>, accentColor: Color = LiquidGlassColors.primaryPink) {
        self._isOn = isOn
        self.accentColor = accentColor
    }
    
    public var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        }) {
            ZStack {
                // 背景轨道
                Capsule()
                    .fill(isOn ? accentColor.opacity(0.3) : Color.white.opacity(0.1))
                    .frame(width: 48, height: 26)
                
                // 玻璃滑块
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    .offset(x: isOn ? 11 : -11)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                    )
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .pressEvents(
            onPress: { withAnimation(.easeInOut(duration: 0.1)) { isPressed = true } },
            onRelease: { withAnimation(.easeInOut(duration: 0.1)) { isPressed = false } }
        )
    }
}

// MARK: - 液态玻璃 TextField
public struct LiquidGlassTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var variant: GlassVariant = .regular
    var isSecure: Bool = false
    var onSubmit: (() -> Void)? = nil
    
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    
    public init(
        _ placeholder: String,
        text: Binding<String>,
        icon: String? = nil,
        variant: GlassVariant = .regular,
        isSecure: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
        self.variant = variant
        self.isSecure = isSecure
        self.onSubmit = onSubmit
    }
    
    public var body: some View {
        HStack(spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isFocused ? LiquidGlassColors.primaryPink : LiquidGlassColors.textTertiary)
            }
            
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(LiquidGlassColors.textPrimary)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit {
                onSubmit?()
            }
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlassSurface(
            isFocused ? .prominent : (isHovered ? .regular : .subtle),
            tint: isFocused ? LiquidGlassColors.primaryPink.opacity(0.1) : nil,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isFocused ? LiquidGlassColors.primaryPink.opacity(0.4) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 液态玻璃输入行 (带标题)
public struct LiquidGlassInputRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    
    public init(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        icon: String? = nil
    ) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(LiquidGlassColors.textSecondary)
                }
                
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LiquidGlassColors.textSecondary)
            }
            .frame(width: 100, alignment: .leading)
            
            TextField(placeholder, text: $text)
                .font(.system(size: 14))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .textFieldStyle(.plain)
                .focused($isFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlassSurface(
            isFocused ? .prominent : (isHovered ? .regular : .subtle),
            tint: isFocused ? LiquidGlassColors.primaryPink.opacity(0.08) : nil,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isFocused ? LiquidGlassColors.primaryPink.opacity(0.3) : Color.clear,
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 液态玻璃搜索框
public struct LiquidGlassSearchField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    
    public init(
        _ placeholder: String,
        text: Binding<String>,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.onSubmit = onSubmit
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? LiquidGlassColors.primaryPink : LiquidGlassColors.textTertiary)
            
            TextField(placeholder, text: $text)
                .font(.system(size: 14))
                .foregroundStyle(LiquidGlassColors.textPrimary)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    onSubmit?()
                }
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(LiquidGlassColors.textTertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlassSurface(
            isFocused ? .prominent : (isHovered ? .regular : .subtle),
            tint: isFocused ? LiquidGlassColors.primaryPink.opacity(0.08) : nil,
            in: Capsule()
        )
        .overlay(
            Capsule()
                .stroke(
                    isFocused ? LiquidGlassColors.primaryPink.opacity(0.35) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 预览
#Preview {
    VStack(spacing: 20) {
        LiquidGlassToggle("自动播放", subtitle: "视频加载后自动开始播放", isOn: .constant(true))
        LiquidGlassToggle("深色模式", isOn: .constant(false))
        
        LiquidGlassTextField("搜索动漫...", text: .constant(""), icon: "magnifyingglass")
        LiquidGlassTextField("输入链接", text: .constant("https://"), icon: "link")
        
        LiquidGlassInputRow("用户名", placeholder: "请输入用户名", text: .constant(""), icon: "person")
        LiquidGlassSearchField("搜索壁纸...", text: .constant(""))
    }
    .padding()
    .background(LiquidGlassColors.deepBackground)
}
