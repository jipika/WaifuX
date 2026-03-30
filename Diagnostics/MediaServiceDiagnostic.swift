import Foundation
import Cocoa

// MARK: - MediaService 诊断测试
// 运行: swift MediaServiceDiagnostic.swift

// 模拟简化的 MediaService 逻辑来诊断问题

actor DiagnosticMediaService {
    static let shared = DiagnosticMediaService()

    private let baseURL = "https://motionbgs.com"

    // 内置配置（从 FavoriteSource.swift 复制）- 已更新支持引号可选的 class 属性
    private let listItemPatterns = [
        #"<a title="([^"]+)" href=([^ >]+)>.*?<img[^>]+src=([^ >]+)[^>]*>.*?<span class=["']?ttl["']?>(.*?)</span>\s*<span class=["']?frm["']?>\s*(.*?)\s*</span>"#,
        #"<a[^>]*title=["']?([^"'>]+)["']?[^>]*href=["']?([^"'\s>]+)["']?[^>]*>.*?<img[^>]+src=["']?([^"'\s>]+)["']?[^>]*>.*?<span[^>]*>([^<]*)</span>\s*<span[^>]*>\s*</span>\s*<span[^>]*>([^<]*)</span>"#
    ]

    private let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
        "Accept-Language": "en-US,en;q=0.9"
    ]

    func runDiagnostics() async {
        print(String(repeating: "=", count: 60))
        print("MediaService 诊断测试")
        print(String(repeating: "=", count: 60))

        // 1. 测试网络请求
        print("\n📡 测试 1: 网络请求")
        let url = URL(string: baseURL)!
        var html = ""

        do {
            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ 响应类型错误")
                return
            }

            print("   HTTP 状态码: \(httpResponse.statusCode)")

            guard (200...299).contains(httpResponse.statusCode) else {
                print("❌ HTTP 错误: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 403 {
                    print("   💡 可能被 Cloudflare 或防火墙阻止")
                }
                return
            }

            html = String(decoding: data, as: UTF8.self)
            print("✅ 成功获取 HTML (\(html.count) 字符)")

            // 检查是否有 Cloudflare 挑战页面
            if html.contains("challenge") || html.contains("cf-browser-verification") {
                print("⚠️ 检测到 Cloudflare 验证页面")
            }

        } catch {
            print("❌ 网络错误: \(error)")
            return
        }

        // 2. 测试正则表达式
        print("\n📝 测试 2: 正则表达式匹配")

        let htmlNSRange = NSRange(html.startIndex..., in: html)
        var totalMatches = 0

        for (index, pattern) in listItemPatterns.enumerated() {
            print("   模式 \(index + 1):")

            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                print("      ❌ 无效的正则表达式")
                continue
            }

            let matches = regex.matches(in: html, options: [], range: htmlNSRange)
            print("      找到 \(matches.count) 个匹配")

            if let firstMatch = matches.first {
                totalMatches += 1
                // 打印第一个匹配的捕获组
                for i in 0..<firstMatch.numberOfRanges {
                    if let range = Range(firstMatch.range(at: i), in: html) {
                        let captured = String(html[range])
                        let preview = captured.prefix(50).replacingOccurrences(of: "\n", with: " ")
                        print("      组 \(i): \(preview)\(captured.count > 50 ? "..." : "")")
                    }
                }
            }
        }

        // 3. 模拟完整解析
        print("\n🔍 测试 3: 完整解析流程")
        let items = parseListPage(html: html)
        print("   解析出 \(items.count) 个项目")

        if let first = items.first {
            print("   第一个项目:")
            print("      ID: \(first.id)")
            print("      标题: \(first.title)")
            print("      缩略图: \(first.thumbnailURL)")
            print("      分辨率: \(first.resolutionLabel)")
        }

        // 4. 检查 HTML 中的关键元素
        print("\n🔎 测试 4: HTML 结构检查")
        let ttlCount = html.components(separatedBy: "class=ttl").count - 1
        let ttlQuotedCount = html.components(separatedBy: "class=\"ttl\"").count - 1
        let frmCount = html.components(separatedBy: "class=frm").count - 1
        let frmQuotedCount = html.components(separatedBy: "class=\"frm\"").count - 1
        let linkCount = html.components(separatedBy: "<a ").count - 1
        print("   <span class=ttl>: \(ttlCount) 个 (无引号)")
        print("   <span class=\"ttl\">: \(ttlQuotedCount) 个 (有引号)")
        print("   <span class=frm>: \(frmCount) 个 (无引号)")
        print("   <span class=\"frm\">: \(frmQuotedCount) 个 (有引号)")
        print("   <a> 标签: \(linkCount) 个")

        print("\n" + String(repeating: "=", count: 60))
        if items.isEmpty {
            print("❌ 诊断结果: 未解析出任何项目")
            print("\n可能的根本原因:")
            print("   1. HTML 结构与正则表达式不匹配")
            print("   2. 网站返回了不同的页面结构")
            print("   3. 被 Cloudflare 或防火墙阻止")
        } else {
            print("✅ 诊断结果: 解析正常工作 (\(items.count) 个项目)")
        }
        print(String(repeating: "=", count: 60))
    }

    private func parseListPage(html: String) -> [DiagnosticMediaItem] {
        let htmlNSRange = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var items: [DiagnosticMediaItem] = []

        for pattern in listItemPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                continue
            }

            for match in regex.matches(in: html, options: [], range: htmlNSRange) {
                guard
                    let title = capture(match: match, in: html, at: 1),
                    let href = capture(match: match, in: html, at: 2),
                    let imageSrc = capture(match: match, in: html, at: 3),
                    let labelText = capture(match: match, in: html, at: 4),
                    let resolutionText = capture(match: match, in: html, at: 5)
                else {
                    continue
                }

                let slug = href
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .components(separatedBy: "/")
                    .first ?? href

                guard !slug.isEmpty, seen.insert(slug).inserted else {
                    continue
                }

                let cleanTitle = labelText.isEmpty ? title : labelText
                let thumbnailURL = makeAbsoluteURL(path: imageSrc)

                items.append(DiagnosticMediaItem(
                    id: slug,
                    title: cleanTitle.htmlDecoded(),
                    thumbnailURL: thumbnailURL,
                    resolutionLabel: resolutionText.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }

        return items
    }

    private func capture(match: NSTextCheckingResult, in text: String, at index: Int) -> String? {
        guard let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func makeAbsoluteURL(path: String) -> URL {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        let base = URL(string: baseURL)!
        let joinedBase = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        return URL(string: joinedBase + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? base
    }
}

// MARK: - 辅助类型

struct DiagnosticMediaItem: Identifiable {
    let id: String
    let title: String
    let thumbnailURL: URL
    let resolutionLabel: String
}

// MARK: - 扩展

extension String {
    func repeating(_ count: Int) -> String {
        String(repeating: self, count: count)
    }

    func htmlDecoded() -> String {
        // 简化的 HTML decode，不依赖 NSAttributedString
        var result = self
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}

// MARK: - 主入口

Task {
    await DiagnosticMediaService.shared.runDiagnostics()
    exit(0)
}

RunLoop.main.run()
