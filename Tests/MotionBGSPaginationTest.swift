#!/usr/bin/env swift
import Foundation
import SwiftSoup

// 模拟实际的 HTML 结构
let html = """
<!DOCTYPE html>
<html>
<body>
<div class="wallpapers">
  <a href="/media/1/wallpaper1/">
    <img src="/i/c/364x205/media/1/wallpaper1.1920x1080.jpg">
  </a>
  <a href="/media/2/wallpaper2/">
    <img src="/i/c/364x205/media/2/wallpaper2.1920x1080.jpg">
  </a>
</div>
<a class="link--arrowed" href="/2/"> View More Wallpapers <svg viewBox="0 0 32 32"></svg>
</body>
</html>
"""

print("=== 测试 SwiftSoup 选择器 ===\n")

do {
    let document = try SwiftSoup.parse(html)
    
    // 测试选择器 a.link--arrowed
    let links = try document.select("a.link--arrowed")
    print("✅ 选择器 'a.link--arrowed' 匹配到 \(links.count) 个元素")
    
    if let link = links.first() {
        let href = try link.attr("href")
        let text = try link.text()
        let className = try link.attr("class")
        
        print("   href: \(href)")
        print("   text: \(text)")
        print("   class: \(className)")
        
        // 验证
        if href == "/2/" {
            print("\n✅ 分页链接提取成功!")
        } else {
            print("\n❌ 分页链接提取失败!")
        }
    } else {
        print("\n❌ 未找到分页链接!")
    }
    
    // 测试其他可能的分页选择器
    print("\n--- 测试其他选择器 ---")
    
    let otherSelectors = [
        "a[href='/2/']",
        "a[href*='/2/']",
        "a[href^='/']",  // 以 / 开头的链接
        "a[href$='/']",  // 以 / 结尾的链接
    ]
    
    for selector in otherSelectors {
        let count = try document.select(selector).count
        print("  \(selector): \(count) 个匹配")
    }
    
} catch {
    print("❌ 错误: \(error)")
}

print("\n=== 使用实际 HTML 测试 ===\n")

// 读取实际保存的 HTML 文件
let fileManager = FileManager.default
if let htmlContent = try? String(contentsOfFile: "/tmp/motionbgs.html", encoding: .utf8) {
    print("HTML 文件大小: \(htmlContent.count) 字节")
    
    do {
        let document = try SwiftSoup.parse(htmlContent)
        
        // 测试 a.link--arrowed
        let arrowedLinks = try document.select("a.link--arrowed")
        print("✅ 'a.link--arrowed' 匹配到 \(arrowedLinks.count) 个元素")
        
        for (index, link) in arrowedLinks.array().enumerated() {
            let href = try link.attr("href")
            let text = try link.text()
            print("  [\(index + 1)] href='\(href)' text='\(text.prefix(30))...'")
        }
        
        // 查找 href="/2/" 的链接
        let page2Links = try document.select("a[href='/2/']")
        print("\n查找 'a[href=\"/2/\"]': \(page2Links.count) 个匹配")
        
        if let link = page2Links.first() {
            let href = try link.attr("href")
            let className = try link.attr("class")
            print("  href: \(href)")
            print("  class: \(className)")
        }
        
    } catch {
        print("❌ 解析 HTML 失败: \(error)")
    }
} else {
    print("❌ 无法读取 HTML 文件")
}

print("\n=== 结论 ===")
print("如果上面显示 '✅ 分页链接提取成功', 说明选择器工作正常")
print("如果显示 '❌', 说明需要进一步调查")
