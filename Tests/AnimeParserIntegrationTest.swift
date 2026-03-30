import Foundation
import SwiftSoup

/// 动漫解析集成测试
/// 使用实际的 HTML 内容测试解析逻辑
struct AnimeParserIntegrationTest {
    
    /// 模拟 AGE 动漫搜索结果页面 HTML
    static let ageSearchHTML = """
    <!DOCTYPE html>
    <html>
    <head><title>AGE 动漫 - 搜索结果</title></head>
    <body>
        <div class="search-results">
            <div class="item">
                <a href="/detail/12345">
                    <img src="https://example.com/cover1.jpg" alt="进击的巨人">
                    <span class="title">进击的巨人 最终季</span>
                </a>
            </div>
            <div class="item">
                <a href="/detail/67890">
                    <img src="https://example.com/cover2.jpg" alt="鬼灭之刃">
                    <span class="title">鬼灭之刃 柱训练篇</span>
                </a>
            </div>
            <div class="item">
                <a href="/detail/11111">
                    <img data-src="https://example.com/cover3.jpg" alt="间谍过家家">
                    <span class="title">间谍过家家 第二季</span>
                </a>
            </div>
        </div>
    </body>
    </html>
    """
    
    /// 模拟 AGE 动漫详情页 HTML
    static let ageDetailHTML = """
    <!DOCTYPE html>
    <html>
    <head><title>进击的巨人 最终季 - AGE 动漫</title></head>
    <body>
        <div class="container">
            <h1 class="page-title">进击的巨人 最终季</h1>
            <img class="cover" src="https://example.com/detail-cover.jpg">
            <div class="desc">
                在这个残酷的世界中,人类为了生存必须与巨人战斗。
                艾伦·耶格尔为了寻找自由,踏上了漫长的旅程...
            </div>
            <div class="status">更新至第16集</div>
            <div class="rating">9.5分</div>
            
            <div class="episode-list">
                <a href="/play/12345/1">
                    <span>第1集</span>
                </a>
                <a href="/play/12345/2">
                    <span>第2集</span>
                </a>
                <a href="/play/12345/3">
                    <span>第3集</span>
                </a>
            </div>
        </div>
    </body>
    </html>
    """
    
    /// 创建测试用的 AGE 规则
    static func createAgeRule() -> AnimeRule {
        return AnimeRule(
            id: "age",
            api: "1",
            type: "anime",
            name: "AGE 动漫",
            version: "1.1.0",
            deprecated: false,
            baseURL: "https://www.agedm.io",
            headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
            ],
            timeout: 30,
            searchURL: "https://www.agedm.io/search?query={keyword}",
            searchList: "a[href*='/detail/']",
            searchName: "a[href*='/detail/']",
            searchCover: "img",
            searchDetail: "a[href*='/detail/']",
            searchId: nil,
            detailTitle: ".page-title, h1.title, h1",
            detailCover: "img.cover, .cover-img img",
            detailDesc: ".desc, .description",
            detailStatus: ".status",
            detailRating: ".rating",
            episodeList: "a[href*='/play/']",
            episodeName: "span",
            episodeLink: "a[href]",
            episodeThumb: "img",
            videoSelector: "iframe[src*='player']",
            videoSourceAttr: "src",
            useWebview: false,
            multiSources: true,
            xpath: nil
        )
    }
    
    /// 测试搜索结果解析
    static func testSearchParsing() -> Bool {
        print("\n=== 测试搜索结果解析 ===")
        
        let rule = createAgeRule()
        
        do {
            let document = try SwiftSoup.parse(ageSearchHTML)
            let listSelector = rule.searchList ?? "a"
            let elements = try document.select(listSelector)
            
            print("✅ 找到 \(elements.count) 个搜索结果")
            
            if elements.count == 0 {
                print("❌ 未找到任何搜索结果")
                return false
            }
            
            var results: [(title: String, cover: String?, detail: String)] = []
            
            for element in elements {
                // 提取标题
                var title: String? = nil
                if let nameSelector = rule.searchName, !nameSelector.isEmpty {
                    title = try? element.select(nameSelector).first()?.text()
                }
                if title == nil {
                    title = try? element.text()
                }
                
                // 提取封面
                var cover: String? = nil
                if let coverSelector = rule.searchCover, !coverSelector.isEmpty {
                    cover = try? element.select(coverSelector).first()?.attr("src")
                        ?? element.select(coverSelector).first()?.attr("data-src")
                }
                
                // 提取详情链接
                var detail: String? = nil
                if let detailSelector = rule.searchDetail, !detailSelector.isEmpty {
                    detail = try? element.select(detailSelector).first()?.attr("href")
                }
                if detail == nil {
                    detail = try? element.select("a").first()?.attr("href")
                }
                
                if let detailURL = detail, !detailURL.isEmpty {
                    results.append((
                        title: title ?? "Untitled",
                        cover: cover,
                        detail: detailURL
                    ))
                }
            }
            
            print("\n✅ 解析结果:")
            for (index, result) in results.enumerated() {
                print("   \(index + 1). \(result.title)")
                print("      封面: \(result.cover ?? "无")")
                print("      详情: \(result.detail)")
            }
            
            // 验证结果
            if results.count == 3 {
                print("\n✅ 搜索结果解析成功!")
                return true
            } else {
                print("\n⚠️ 解析数量不匹配: 期望 3, 实际 \(results.count)")
                return false
            }
            
        } catch {
            print("❌ 解析失败: \(error)")
            return false
        }
    }
    
    /// 测试详情页解析
    static func testDetailParsing() -> Bool {
        print("\n=== 测试详情页解析 ===")
        
        let rule = createAgeRule()
        
        do {
            let document = try SwiftSoup.parse(ageDetailHTML)
            
            // 提取标题
            let title = try document.select(rule.detailTitle ?? "h1").first()?.text() ?? "Unknown"
            print("✅ 标题: \(title)")
            
            // 提取封面
            let cover = try? document.select(rule.detailCover ?? "img").first()?.attr("src")
            print("✅ 封面: \(cover ?? "无")")
            
            // 提取描述
            let description = try? document.select(rule.detailDesc ?? "p").first()?.text()
            print("✅ 描述: \(description ?? "无")")
            
            // 提取状态
            let status = try? document.select(rule.detailStatus ?? "span").first()?.text()
            print("✅ 状态: \(status ?? "无")")
            
            // 提取评分
            let rating = try? document.select(rule.detailRating ?? "span").first()?.text()
            print("✅ 评分: \(rating ?? "无")")
            
            // 提取剧集列表
            if let listSelector = rule.episodeList {
                let episodeElements = try document.select(listSelector)
                print("\n✅ 找到 \(episodeElements.count) 集")
                
                for (index, element) in episodeElements.array().enumerated() {
                    let name = try? element.select(rule.episodeName ?? "span").first()?.text()
                    let link = try? element.select(rule.episodeLink ?? "a").first()?.attr("href")
                    print("   第\(index + 1)集: \(name ?? "未知") - \(link ?? "无链接")")
                }
                
                if episodeElements.count == 3 {
                    print("\n✅ 详情页解析成功!")
                    return true
                } else {
                    print("\n⚠️ 剧集数量不匹配: 期望 3, 实际 \(episodeElements.count)")
                    return false
                }
            } else {
                print("❌ 未配置剧集列表选择器")
                return false
            }
            
        } catch {
            print("❌ 解析失败: \(error)")
            return false
        }
    }
    
    /// 测试相对路径转换
    static func testURLConversion() -> Bool {
        print("\n=== 测试相对路径转换 ===")
        
        let baseURL = "https://www.agedm.io"
        
        let testCases = [
            ("/detail/12345", "https://www.agedm.io/detail/12345"),
            ("/play/12345/1", "https://www.agedm.io/play/12345/1"),
            ("https://example.com/test", "https://example.com/test"),
            ("//cdn.example.com/img.jpg", "https://cdn.example.com/img.jpg")
        ]
        
        var allPassed = true
        
        for (relative, expected) in testCases {
            let absolute = HTMLParser.shared.makeAbsoluteURL(relative, baseURL: baseURL)
            let passed = absolute == expected
            allPassed = allPassed && passed
            
            print("  \(passed ? "✅" : "❌") \(relative)")
            print("      期望: \(expected)")
            print("      实际: \(absolute ?? "nil")")
        }
        
        return allPassed
    }
    
    /// 运行所有集成测试
    static func runAllTests() {
        print("\n" + String(repeating: "=", count: 70))
        print("开始运行动漫解析集成测试")
        print(String(repeating: "=", count: 70))
        
        let searchResult = testSearchParsing()
        let detailResult = testDetailParsing()
        let urlResult = testURLConversion()
        
        print("\n" + String(repeating: "=", count: 70))
        print("测试结果汇总:")
        print("  搜索结果解析: \(searchResult ? "✅ 通过" : "❌ 失败")")
        print("  详情页解析: \(detailResult ? "✅ 通过" : "❌ 失败")")
        print("  URL 转换: \(urlResult ? "✅ 通过" : "❌ 失败")")
        print(String(repeating: "=", count: 70))
        
        if searchResult && detailResult && urlResult {
            print("\n🎉 所有集成测试通过!")
            print("CSS Selector 解析逻辑工作正常")
        } else {
            print("\n⚠️ 部分测试失败,需要检查解析逻辑")
        }
    }
}
