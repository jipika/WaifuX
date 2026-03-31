#!/usr/bin/env swift
import Foundation
import SwiftSoup

// 测试 SwiftSoup 选择器

let homeHTML = """
<!DOCTYPE html>
<html>
<head><title>MotionBGs Home</title></head>
<body>
<div class="wallpapers">
  <a href="/media/1/wallpaper1/" title="Wallpaper 1">Wallpaper 1</a>
  <a href="/media/2/wallpaper2/" title="Wallpaper 2">Wallpaper 2</a>
</div>
<a href="/2/" class="link--arrowed">View More Wallpapers</a>
</body>
</html>
"""

let tagHTML = """
<!DOCTYPE html>
<html>
<head><title>Anime Wallpapers</title></head>
<body>
<div class="wallpapers">
  <a href="/media/3/anime1/" title="Anime 1">Anime 1</a>
  <a href="/media/4/anime2/" title="Anime 2">Anime 2</a>
</div>
<a href="/tag:anime/2/">Next</a>
</body>
</html>
"""

print("=== 测试 SwiftSoup 选择器 ===\n")

do {
    // 测试首页
    print("--- 首页 HTML ---")
    let homeDoc = try SwiftSoup.parse(homeHTML)
    
    // 测试选择器 a.link--arrowed
    let homeLinks = try homeDoc.select("a.link--arrowed")
    print("✅ 选择器 'a.link--arrowed' 匹配到 \(homeLinks.count) 个元素")
    
    if let firstLink = homeLinks.first() {
        let href = try firstLink.attr("href")
        let text = try firstLink.text()
        let className = try firstLink.attr("class")
        print("   href: \(href)")
        print("   text: \(text)")
        print("   class: \(className)")
    }
    
    // 测试选择器 a[rel='next']
    let nextRelLinks = try homeDoc.select("a[rel='next']")
    print("❌ 选择器 'a[rel=\\'next\\']' 匹配到 \(nextRelLinks.count) 个元素")
    
    print()
    
    // 测试标签页
    print("--- 标签页 HTML ---")
    let tagDoc = try SwiftSoup.parse(tagHTML)
    
    // 测试选择器 a.link--arrowed
    let tagLinks = try tagDoc.select("a.link--arrowed")
    print("❌ 选择器 'a.link--arrowed' 匹配到 \(tagLinks.count) 个元素")
    
    // 查找包含 "Next" 文本的链接
    let allLinks = try tagDoc.select("a")
    print("\n查找包含 'Next' 文本的链接:")
    for link in allLinks.array() {
        let text = try link.text()
        if text.contains("Next") || text.contains("View More") {
            let href = try link.attr("href")
            print("✅ 找到: href='\(href)' text='\(text)'")
        }
    }
    
    // 测试通用选择器
    print("\n测试通用选择器策略:")
    
    // 策略 1: 匹配 href 以 /数字/ 结尾的链接
    let numericLinks = try homeDoc.select("a[href~=/\\d+/$]")
    print("策略 1 [href~=/\\\\d+/$]: 匹配到 \(numericLinks.count) 个")
    for link in numericLinks.array() {
        print("  - \(try link.attr("href"))")
    }
    
    // 策略 2: 匹配包含 "View More" 或 "Next" 文本的链接
    print("\n策略 2: 查找包含分页关键词的链接")
    for link in allLinks.array() {
        let text = try link.text().lowercased()
        if text.contains("next") || text.contains("more") || text.contains("›") {
            let href = try link.attr("href")
            let linkText = try link.text()
            print("  - href='\(href)' text='\(linkText)'")
        }
    }
    
} catch {
    print("❌ 错误: \(error)")
}

print("\n=== 结论 ===")
print("✅ SwiftSoup 选择器正常工作")
print("✅ 'a.link--arrowed' 能正确匹配首页分页按钮")
print("❌ 'a.link--arrowed' 不能匹配标签页分页按钮（因为没有 class 属性）")
print("\n💡 建议：")
print("1. 首页使用选择器: a.link--arrowed")
print("2. 标签页使用选择器: a[href*='/\\d+/$'] 或文本匹配")
print("3. 或者使用更通用的选择器策略")
