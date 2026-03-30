import Foundation
import SwiftSoup

// MARK: - 动漫解析测试

/// 测试动漫解析功能
/// 使用方法: 在项目中运行此测试文件来验证修复
actor AnimeParserTest {
    
    /// 测试 API v1 规则解析
    static func testAPIV1Parsing() async {
        print("🧪 Testing API v1 parsing...")
        
        // 模拟 age.json 的规则配置
        let ageRule = AnimeRule(
            id: "age",
            api: "1",
            type: "anime",
            name: "AGE 动漫",
            version: "1.1.0",
            deprecated: false,
            baseURL: "https://www.agedm.io",
            headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "Accept-Language": "zh-CN,zh;q=0.9"
            ],
            timeout: 30,
            searchURL: "https://www.agedm.io/search?query={keyword}",
            searchList: "a[href*='/detail/']",
            searchName: "a[href*='/detail/']",
            searchCover: "img",
            searchDetail: "a[href*='/detail/']",
            detailTitle: ".page-title, h1.title, h1",
            detailCover: "img.cover, .cover-img img",
            detailDesc: ".desc, .description",
            detailStatus: ".status, .info-item",
            detailRating: ".rating, .score",
            episodeList: "a[href*='/play/']",
            episodeName: "span",
            episodeLink: "a[href]",
            episodeThumb: "img",
            videoSelector: "iframe[src*='player']",
            videoSourceAttr: "src",
            useWebview: false,
            multiSources: true
        )
        
        do {
            let results = try await AnimeParser.shared.search(query: "进击的巨人", rules: [ageRule])
            print("✅ Found \(results.count) results")
            
            if let first = results.first {
                print("📺 First result: \(first.title)")
                print("🔗 Detail URL: \(first.detailURL)")
                
                // 测试详情解析
                let detail = try await AnimeParser.shared.fetchDetail(detailURL: first.detailURL, rule: ageRule)
                print("✅ Detail parsed: \(detail.title)")
                print("📺 Episodes: \(detail.episodes.count)")
            }
        } catch {
            print("❌ Test failed: \(error)")
        }
    }
    
    /// 测试 API v2 规则解析 (兼容 Kazumi)
    static func testAPIV2Parsing() async {
        print("🧪 Testing API v2 (XPath) parsing...")
        
        // 模拟 gimy.json 的规则配置 (XPath 格式)
        let gimyRule = AnimeRule(
            id: "gimy",
            api: "2",
            type: "anime",
            name: "Gimy 动漫",
            version: "1.0.0",
            deprecated: false,
            baseURL: "https://gimy.ai",
            headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
            ],
            timeout: 30,
            searchURL: "https://gimy.ai/search?q={keyword}",
            xpath: AnimeXPathRules(
                search: AnimeSearchXPath(
                    url: "https://gimy.ai/search?q={keyword}",
                    list: "//div[contains(@class, 'video-item')]",
                    title: ".//h3/a/text()",
                    cover: ".//img/@data-src",
                    detail: ".//h3/a/@href",
                    id: ".//a/@href"
                ),
                detail: AnimeDetailXPath(
                    title: "//h1[@class='title']/text()",
                    cover: "//div[@class='poster']/img/@src",
                    description: "//div[@class='summary']/text()",
                    episodes: "//a[contains(@class, 'episode-link')]",
                    episodeName: ".//text()",
                    episodeLink: ".//@href",
                    episodeThumb: ".//img/@src"
                ),
                list: nil
            )
        )
        
        do {
            let results = try await AnimeParser.shared.search(query: "鬼灭之刃", rules: [gimyRule])
            print("✅ Found \(results.count) results")
        } catch {
            print("❌ Test failed: \(error)")
        }
    }
    
    /// 运行所有测试
    static func runAllTests() async {
        print("🚀 Running Anime Parser Tests...")
        print("===============================\n")
        
        await testAPIV1Parsing()
        print("\n")
        await testAPIV2Parsing()
        
        print("\n===============================")
        print("✅ All tests completed!")
    }
}

// MARK: - 使用方法
/*
 在 AppDelegate 或合适的入口调用:
 
 Task {
     await AnimeParserTest.runAllTests()
 }
 
 或者在 ViewModel 中测试:
 
 func testAnimeParsing() async {
     await AnimeParserTest.testAPIV1Parsing()
 }
 */
