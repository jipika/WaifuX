import Foundation
import Kanna

// MARK: - XPath HTML 解析器 (用于 Kazumi 规则)

class HTMLXPathParser {

    /// 使用 XPath 解析搜索结果
    /// 参考 Kazumi Plugin.queryBangumi
    static func parseSearchResults(
        html: String,
        searchList: String,
        searchName: String,
        searchResult: String,
        searchQuery: String? = nil
    ) throws -> [(name: String, src: String)] {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            throw AnimeParserError.parseError("无法解析 HTML")
        }

        var results: [(name: String, src: String)] = []

        // 无效标题列表（导航、页脚等常见非内容链接）
        let invalidTitles = ["首页", "主页", "home", "上一页", "下一页", "尾页", "关于我们", "联系我们", "帮助", "登录", "注册"]
        _ = ["/", "/index.html", "/index.php", "#", ""] // invalidPaths 保留供将来使用

        // 搜索查询关键词（用于匹配度评分）
        let queryKeywords = searchQuery?.lowercased().components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty } ?? []

        // 使用 searchList XPath 查找所有结果项
        let elements = doc.xpath(searchList)

        for element in elements {
            do {
                // 将绝对 XPath 转换为相对 XPath（在当前元素内查找）
                let relativeSearchName = makeRelativeXPath(searchName)
                let relativeSearchResult = makeRelativeXPath(searchResult)

                // 提取标题
                let nameNode = element.xpath(relativeSearchName).first
                let name = nameNode?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // 提取链接 (href 属性)
                let resultNode = element.xpath(relativeSearchResult).first
                var src = ""
                if let node = resultNode {
                    // 尝试获取 href 属性
                    src = node["href"] ?? ""
                }

                // 过滤无效标题
                let lowerTitle = name.lowercased()
                if invalidTitles.contains(where: { lowerTitle == $0.lowercased() || lowerTitle.hasPrefix($0.lowercased()) }) {
                    print("[HTMLXPathParser] ⚠️ 跳过导航项: \(name)")
                    continue
                }

                // 拉丁语系关键词启发式（CJK 检索跳过，避免葬送的芙莉莲等零结果）
                if AnimeSearchHeuristics.shouldApplyStrictTitleKeywordFilter(searchQuery: searchQuery),
                   !queryKeywords.isEmpty {
                    let titleKeywords = lowerTitle.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).filter { !$0.isEmpty }
                    let hasMatchingKeyword = queryKeywords.contains { queryWord in
                        titleKeywords.contains { titleWord in
                            titleWord.contains(queryWord) || queryWord.contains(titleWord)
                        }
                    }
                    if !hasMatchingKeyword && name.count < 10 {
                        print("[HTMLXPathParser] ⚠️ 跳过低匹配度结果: \(name)")
                        continue
                    }
                }

                // 过滤无效路径（只匹配完整的无效路径，不使用 hasSuffix 避免误判）
                let lowerSrc = src.lowercased()
                let invalidPaths = ["/", "/index.html", "/index.php", "#", ""]
                if invalidPaths.contains(lowerSrc) {
                    print("[HTMLXPathParser] ⚠️ 跳过无效链接: \(src) (标题: \(name))")
                    continue
                }
                
                // 额外检查：过滤常见的首页/导航链接（必须以 / 开头且没有路径深度）
                if lowerSrc == "/" || lowerSrc == "/index.html" || lowerSrc == "/index.php" {
                    print("[HTMLXPathParser] ⚠️ 跳过首页链接: \(src) (标题: \(name))")
                    continue
                }

                // 过滤纯锚点链接
                if src.hasPrefix("#") {
                    print("[HTMLXPathParser] ⚠️ 跳过锚点链接: \(src)")
                    continue
                }

                if !name.isEmpty && !src.isEmpty {
                    results.append((name: name, src: src))
                }
            }
        }

        return results
    }

    /// 使用 XPath 解析剧集列表 (Roads)
    /// 参考 Kazumi Plugin.querychapterRoads
    static func parseChapterRoads(
        html: String,
        chapterRoads: String,
        chapterResult: String
    ) throws -> [(roadName: String, episodes: [(name: String, url: String)])] {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            throw AnimeParserError.parseError("无法解析 HTML")
        }

        var roads: [(roadName: String, episodes: [(name: String, url: String)])] = []

        // 使用 chapterRoads XPath 查找所有播放列表
        let roadElements = doc.xpath(chapterRoads)

        var count = 1
        for element in roadElements {
            var chapterUrlList: [String] = []
            var chapterNameList: [String] = []

            // 使用 chapterResult XPath 查找该播放列表下的所有剧集
            // 转换为相对 XPath，确保在当前播放列表容器内查找
            let relativeChapterResult = makeRelativeXPath(chapterResult)
            let episodeElements = element.xpath(relativeChapterResult)

            for item in episodeElements {
                let itemUrl = item["href"] ?? ""
                let itemName = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

                if !itemUrl.isEmpty && !itemName.isEmpty {
                    chapterUrlList.append(itemUrl)
                    chapterNameList.append(itemName)
                }
            }

            if !chapterUrlList.isEmpty && !chapterNameList.isEmpty {
                let roadName = "播放列表\(count)"
                let episodes = zip(chapterNameList, chapterUrlList).map { (name, url) in
                    (name: name, url: url)
                }
                roads.append((roadName: roadName, episodes: episodes))
                count += 1
            }
        }

        return roads
    }

    /// 检测验证码
    /// 参考 Kazumi 的 antiCrawlerConfig 检测
    static func detectCaptcha(
        html: String,
        captchaImageXPath: String?,
        captchaButtonXPath: String?
    ) -> Bool {
        guard let doc = try? HTML(html: html, encoding: .utf8) else {
            return false
        }

        // 检查验证码图片
        if let imageXPath = captchaImageXPath, !imageXPath.isEmpty {
            if doc.xpath(imageXPath).first != nil {
                return true
            }
        }

        // 检查验证码按钮
        if let buttonXPath = captchaButtonXPath, !buttonXPath.isEmpty {
            if doc.xpath(buttonXPath).first != nil {
                return true
            }
        }

        return false
    }

    // MARK: - 辅助方法

    /// 将绝对 XPath 转换为相对 XPath
    /// 在 element.xpath() 中使用时，绝对路径（如 //div）会在整个文档中查找
    /// 而相对路径（如 .//div）才会在当前元素内部查找
    static func makeRelativeXPath(_ xpath: String) -> String {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 如果已经是相对路径，直接返回
        if trimmed.hasPrefix(".") {
            return trimmed
        }

        // 将 // 开头的 XPath 转换为 .// 开头的相对 XPath
        if trimmed.hasPrefix("//") {
            return "." + trimmed
        }

        // 其他情况（如绝对路径 /html/body/...）也转换为相对路径
        if trimmed.hasPrefix("/") {
            return "." + trimmed
        }

        return trimmed
    }
}
