import SwiftUI

// MARK: - Hero 驱动调色板
// 用于根据当前壁纸动态生成配色方案
struct HeroDrivenPalette {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let backdropTop: Color
    let backdropMid: Color
    let surfaceTop: Color
    let surfaceMid: Color
    let surfaceBottom: Color
    let heroCanvasTop: Color
    let heroCanvasMid: Color
    let heroCanvasBottom: Color
    
    init(wallpaper: Wallpaper?) {
        guard let wallpaper = wallpaper else {
            // 默认配色 - 使用深色玻璃风格
            self.primary = Color(hex: "FF3366")
            self.secondary = Color(hex: "8B5CF6")
            self.tertiary = Color(hex: "3B8BFF")
            self.backdropTop = Color(hex: "1A1A2E")
            self.backdropMid = Color(hex: "12121F")
            self.surfaceTop = Color(hex: "2A2A3E")
            self.surfaceMid = Color(hex: "1E1E32")
            self.surfaceBottom = Color(hex: "151525")
            self.heroCanvasTop = Color(hex: "2D1B4E")
            self.heroCanvasMid = Color(hex: "1A0A2E")
            self.heroCanvasBottom = Color(hex: "0D0D0D")
            return
        }
        
        // 从壁纸颜色中提取
        let colors = wallpaper.colors.prefix(3).map { Color(hex: $0) }
        
        if colors.count >= 3 {
            self.primary = colors[0]
            self.secondary = colors[1]
            self.tertiary = colors[2]
        } else if colors.count == 2 {
            self.primary = colors[0]
            self.secondary = colors[1]
            self.tertiary = Color(hex: "3B8BFF")
        } else if colors.count == 1 {
            self.primary = colors[0]
            self.secondary = colors[0].opacity(0.7)
            self.tertiary = Color(hex: "3B8BFF")
        } else {
            // 根据分类使用默认配色
            switch wallpaper.category.lowercased() {
            case "anime":
                self.primary = Color(hex: "FF3366")
                self.secondary = Color(hex: "8B5CF6")
                self.tertiary = Color(hex: "FF9ED2")
            case "people":
                self.primary = Color(hex: "D98FBF")
                self.secondary = Color(hex: "8F6A5E")
                self.tertiary = Color(hex: "D5B29D")
            default:
                self.primary = Color(hex: "5A6578")
                self.secondary = Color(hex: "3A414E")
                self.tertiary = Color(hex: "8A6A58")
            }
        }
        
        // 生成背景色 - 混合壁纸主色与深色背景（增强可见度）
        self.backdropTop = self.primary.opacity(0.22)
        self.backdropMid = self.secondary.opacity(0.15)

        // 表面色
        self.surfaceTop = self.primary.opacity(0.28)
        self.surfaceMid = self.secondary.opacity(0.20)
        self.surfaceBottom = self.tertiary.opacity(0.12)

        // Canvas 渐变色
        self.heroCanvasTop = self.primary.opacity(0.40)
        self.heroCanvasMid = self.secondary.opacity(0.28)
        self.heroCanvasBottom = Color(hex: "0D0D0D")
    }
}
