import Foundation

/// 动漫解析测试运行器
/// 运行所有测试并生成报告
struct AnimeParserTests {
    
    /// 运行所有测试
    static func runAllTests() {
        print("\n")
        print("╔══════════════════════════════════════════════════════════════════╗")
        print("║          动漫解析功能测试套件                                    ║")
        print("║          Anime Parser Test Suite                                ║")
        print("╚══════════════════════════════════════════════════════════════════╝")
        print("\n")
        
        // 测试 1: 模型解码测试
        print("【测试 1】AnimeRule 模型解码测试")
        print(String(repeating: "-", count: 70))
        AnimeRuleDecodingTest.runAllTests()
        
        print("\n\n")
        
        // 测试 2: 集成测试
        print("【测试 2】CSS Selector 解析集成测试")
        print(String(repeating: "-", count: 70))
        AnimeParserIntegrationTest.runAllTests()
        
        print("\n\n")
        
        // 测试总结
        print("╔══════════════════════════════════════════════════════════════════╗")
        print("║                    测试执行完成                                  ║")
        print("╚══════════════════════════════════════════════════════════════════╝")
        print("\n")
        print("📝 测试说明:")
        print("   1. 模型解码测试验证 JSON 解析能力")
        print("   2. 集成测试验证 CSS Selector 解析逻辑")
        print("   3. 所有测试使用远程仓库的实际规则格式")
        print("\n")
        print("✅ 如果所有测试通过,说明解析逻辑工作正常")
        print("⚠️  如果测试失败,请检查:")
        print("   - AnimeRule 模型字段定义")
        print("   - AnimeParser 解析逻辑")
        print("   - HTMLParser 辅助方法")
        print("\n")
    }
}
