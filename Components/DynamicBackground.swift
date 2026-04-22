import SwiftUI

struct DynamicBackground: View {
    let wallpapers: [Wallpaper]
    let currentIndex: Int
    
    var body: some View {
        // Simple gradient background that changes based on current wallpaper
        GeometryReader { geometry in
            LinearGradient(
                colors: backgroundColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: currentIndex)
        }
    }
    
    private var backgroundColors: [Color] {
        guard currentIndex < wallpapers.count else {
            return [Color(hex: "0D0D0D"), Color(hex: "1a1a2e")]
        }
        
        let wallpaper = wallpapers[currentIndex]
        
        // Generate colors based on category
        switch wallpaper.category.lowercased() {
        case "anime":
            return [Color(hex: "1a0a2e"), Color(hex: "0D0D0D")]
        case "people":
            return [Color(hex: "2d1b4e"), Color(hex: "0D0D0D")]
        default:
            return [Color(hex: "0f1419"), Color(hex: "0D0D0D")]
        }
    }
}

// MARK: - 聚光灯背景效果
/// 柔和自然的聚光灯效果 - 大面积径向渐变 + 底部反光
struct SpotlightBackground: View {
    /// 光源颜色（默认为白色/淡灰色）
    let lightColor: Color
    
    /// 背景颜色（默认为纯黑）
    let backgroundColor: Color
    
    /// 光源强度（0-1）
    let intensity: Double
    
    /// 光束扩散角度（控制锥形宽度）
    let spread: Double
    
    init(
        lightColor: Color = Color.white.opacity(0.85),
        backgroundColor: Color = Color.black,
        intensity: Double = 0.7,
        spread: Double = 0.5
    ) {
        self.lightColor = lightColor
        self.backgroundColor = backgroundColor
        self.intensity = intensity
        self.spread = spread
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 基础黑色背景
                backgroundColor
                
                // 顶部大面积柔和光源 - 使用径向渐变模拟
                RadialGradient(
                    colors: [
                        lightColor.opacity(intensity * 0.6),
                        lightColor.opacity(intensity * 0.25),
                        lightColor.opacity(intensity * 0.08),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: geometry.size.height * 0.85
                )
                
                // 顶部中央强烈高光核心
                VStack {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    lightColor.opacity(intensity),
                                    lightColor.opacity(intensity * 0.6),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: geometry.size.width * 0.25
                            )
                        )
                        .frame(width: geometry.size.width * 0.5, height: 60)
                        .blur(radius: 15)
                        .offset(y: -20)
                    
                    Spacer()
                }
                
                // 中央垂直光束 - 使用线性渐变 + 高模糊
                VStack {
                    LinearGradient(
                        colors: [
                            lightColor.opacity(intensity * 0.35),
                            lightColor.opacity(intensity * 0.15),
                            lightColor.opacity(intensity * 0.05),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: geometry.size.width * spread * 0.7)
                    .frame(maxWidth: .infinity)
                    .blur(radius: 40)
                    
                    Spacer()
                }
                .padding(.top, 20)
                
                // 底部地面反光 - 光照射到地面的效果
                VStack {
                    Spacer()
                    ZStack {
                        // 主反光椭圆
                        Ellipse()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        lightColor.opacity(intensity * 0.5),
                                        lightColor.opacity(intensity * 0.25),
                                        lightColor.opacity(intensity * 0.1),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: geometry.size.width * 0.4
                                )
                            )
                            .frame(width: geometry.size.width * spread * 1.5, height: 80)
                            .blur(radius: 12)
                        
                        // 内层更亮的反光核心
                        Ellipse()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        lightColor.opacity(intensity * 0.7),
                                        lightColor.opacity(intensity * 0.3),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: geometry.size.width * 0.2
                                )
                            )
                            .frame(width: geometry.size.width * spread * 0.8, height: 40)
                            .blur(radius: 6)
                    }
                    .offset(y: -10)
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// 梯形形状 - 用于创建光束的锥形效果（备用）
struct TrapezoidShape: Shape {
    let topWidth: CGFloat
    let bottomWidth: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let topLeft = CGPoint(x: rect.midX - rect.width * topWidth / 2, y: rect.minY)
        let topRight = CGPoint(x: rect.midX + rect.width * topWidth / 2, y: rect.minY)
        let bottomLeft = CGPoint(x: rect.midX - rect.width * bottomWidth / 2, y: rect.maxY)
        let bottomRight = CGPoint(x: rect.midX + rect.width * bottomWidth / 2, y: rect.maxY)
        
        path.move(to: topLeft)
        path.addLine(to: topRight)
        path.addLine(to: bottomRight)
        path.addLine(to: bottomLeft)
        path.closeSubpath()
        
        return path
    }
}

/// 径向渐变聚光灯背景（简化版本）
struct RadialSpotlightBackground: View {
    let centerColor: Color
    let edgeColor: Color
    let spotlightPosition: UnitPoint
    
    init(
        centerColor: Color = Color.white.opacity(0.3),
        edgeColor: Color = Color.black,
        spotlightPosition: UnitPoint = .top
    ) {
        self.centerColor = centerColor
        self.edgeColor = edgeColor
        self.spotlightPosition = spotlightPosition
    }
    
    var body: some View {
        GeometryReader { geometry in
            // 使用两个径向渐变叠加
            ZStack {
                // 基础深色背景
                edgeColor
                
                // 顶部聚光灯效果
                RadialGradient(
                    colors: [
                        centerColor.opacity(0.8),
                        centerColor.opacity(0.3),
                        Color.clear
                    ],
                    center: spotlightPosition,
                    startRadius: 0,
                    endRadius: geometry.size.height * 0.8
                )
                
                // 底部暗角（增强对比）
                RadialGradient(
                    colors: [
                        Color.clear,
                        edgeColor.opacity(0.5)
                    ],
                    center: .bottom,
                    startRadius: 0,
                    endRadius: geometry.size.height * 0.5
                )
            }
            .ignoresSafeArea()
        }
    }
}
