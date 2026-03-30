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
