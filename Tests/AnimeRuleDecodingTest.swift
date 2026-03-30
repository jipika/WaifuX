import Foundation

/// 测试 AnimeRule 模型的 JSON 解码能力
/// 使用远程仓库的实际规则进行验证
struct AnimeRuleDecodingTest {
    
    /// AGE 动漫源规则 (来自远程仓库)
    static let ageJSON = """
    {
      "id": "age",
      "api": "1",
      "type": "anime",
      "name": "AGE 动漫",
      "version": "1.1.0",
      "deprecated": false,
      "baseURL": "https://www.agedm.io",
      "headers": {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Referer": "https://www.agedm.io/"
      },
      "timeout": 30,
      "searchURL": "https://www.agedm.io/search?query={keyword}",
      "searchList": "a[href*='/detail/'], link[url*='/detail/']",
      "searchName": "a[href*='/detail/'], link[url*='/detail/']",
      "searchCover": "img",
      "searchDetail": "a[href*='/detail/']",
      "searchId": "a[href*='/detail/']",
      "detailTitle": ".page-title, h1.title, h1",
      "detailCover": "img.cover, .cover-img img, img[data-original]",
      "detailDesc": ".desc, .description, .content",
      "detailStatus": ".status, .info-item",
      "detailRating": ".rating, .score",
      "episodeList": "a[href*='/play/'], .episode-list a, ul.episode-list li a",
      "episodeName": "span, .episode-title",
      "episodeLink": "a[href]",
      "episodeThumb": "img",
      "videoSelector": "iframe[src*='player'], iframe[src*='embed'], #player iframe",
      "videoSourceAttr": "src",
      "useWebview": false,
      "multiSources": true
    }
    """
    
    /// Gimy 动漫源规则 (来自远程仓库)
    static let gimyJSON = """
    {
      "id": "gimy",
      "api": "1",
      "type": "anime",
      "name": "Gimy 动漫",
      "version": "1.0.0",
      "deprecated": false,
      "baseURL": "https://gimy.ai",
      "timeout": 30,
      "searchURL": "https://gimy.ai/search?keyword={keyword}",
      "searchList": "a[href*='/voddetail/']",
      "searchName": "a[href*='/voddetail/']",
      "searchCover": "img",
      "searchDetail": "a[href*='/voddetail/']",
      "detailTitle": "h1",
      "detailCover": "img",
      "episodeList": "a[href*='/vodplay/']"
    }
    """
    
    /// 测试解码 AGE 规则
    static func testAgeRuleDecoding() -> Bool {
        print("\n=== 测试 AGE 动漫规则解码 ===")
        
        guard let data = ageJSON.data(using: .utf8) else {
            print("❌ 无法将 JSON 字符串转为 Data")
            return false
        }
        
        do {
            let rule = try JSONDecoder().decode(AnimeRule.self, from: data)
            
            // 验证基本字段
            print("✅ 成功解码规则:")
            print("   - ID: \(rule.id)")
            print("   - API: \(rule.api)")
            print("   - 名称: \(rule.name)")
            print("   - 版本: \(rule.version)")
            print("   - BaseURL: \(rule.baseURL)")
            
            // 验证搜索配置
            print("\n✅ 搜索配置:")
            print("   - searchURL: \(rule.searchURL)")
            print("   - searchList: \(rule.searchList ?? "nil")")
            print("   - searchName: \(rule.searchName ?? "nil")")
            print("   - searchCover: \(rule.searchCover ?? "nil")")
            print("   - searchDetail: \(rule.searchDetail ?? "nil")")
            
            // 验证详情配置
            print("\n✅ 详情配置:")
            print("   - detailTitle: \(rule.detailTitle ?? "nil")")
            print("   - detailCover: \(rule.detailCover ?? "nil")")
            print("   - detailDesc: \(rule.detailDesc ?? "nil")")
            
            // 验证剧集配置
            print("\n✅ 剧集配置:")
            print("   - episodeList: \(rule.episodeList ?? "nil")")
            print("   - episodeName: \(rule.episodeName ?? "nil")")
            print("   - episodeLink: \(rule.episodeLink ?? "nil")")
            
            // 验证视频配置
            print("\n✅ 视频配置:")
            print("   - videoSelector: \(rule.videoSelector ?? "nil")")
            print("   - multiSources: \(rule.multiSources ?? false)")
            
            // 验证 Headers
            if let headers = rule.headers {
                print("\n✅ 请求头:")
                for (key, value) in headers {
                    print("   - \(key): \(value.prefix(50))...")
                }
            }
            
            return true
            
        } catch {
            print("❌ 解码失败: \(error)")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, _):
                    print("   缺少字段: \(key.stringValue)")
                case .typeMismatch(let type, let context):
                    print("   类型不匹配: 期望 \(type), 路径: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                case .valueNotFound(let type, let context):
                    print("   值不存在: \(type), 路径: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                case .dataCorrupted(let context):
                    print("   数据损坏: \(context.debugDescription)")
                @unknown default:
                    print("   未知错误")
                }
            }
            return false
        }
    }
    
    /// 测试解码 Gimy 规则
    static func testGimyRuleDecoding() -> Bool {
        print("\n=== 测试 Gimy 动漫规则解码 ===")
        
        guard let data = gimyJSON.data(using: .utf8) else {
            print("❌ 无法将 JSON 字符串转为 Data")
            return false
        }
        
        do {
            let rule = try JSONDecoder().decode(AnimeRule.self, from: data)
            
            print("✅ 成功解码规则:")
            print("   - ID: \(rule.id)")
            print("   - API: \(rule.api)")
            print("   - 名称: \(rule.name)")
            print("   - BaseURL: \(rule.baseURL)")
            
            // 验证可选字段
            print("\n✅ 可选字段测试:")
            print("   - Headers: \(rule.headers == nil ? "nil ✓" : "有值")")
            print("   - detailStatus: \(rule.detailStatus ?? "nil")")
            print("   - detailRating: \(rule.detailRating ?? "nil")")
            print("   - episodeName: \(rule.episodeName ?? "nil")")
            
            return true
            
        } catch {
            print("❌ 解码失败: \(error)")
            return false
        }
    }
    
    /// 运行所有解码测试
    static func runAllTests() {
        print("\n" + String(repeating: "=", count: 60))
        print("开始运行 AnimeRule 解码测试")
        print(String(repeating: "=", count: 60))
        
        let ageResult = testAgeRuleDecoding()
        let gimyResult = testGimyRuleDecoding()
        
        print("\n" + String(repeating: "=", count: 60))
        print("测试结果汇总:")
        print("  AGE 规则解码: \(ageResult ? "✅ 通过" : "❌ 失败")")
        print("  Gimy 规则解码: \(gimyResult ? "✅ 通过" : "❌ 失败")")
        print(String(repeating: "=", count: 60))
        
        if ageResult && gimyResult {
            print("\n🎉 所有解码测试通过!")
            print("AnimeRule 模型可以正确解析远程仓库的规则格式")
        } else {
            print("\n⚠️ 部分测试失败,需要检查模型定义")
        }
    }
}
