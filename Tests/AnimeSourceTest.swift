import Foundation

/// 测试动漫源的实际可用性
/// 使用真实的动漫名称进行搜索测试
struct AnimeSourceTest {
    
    /// 测试用例
    static let testCases: [(source: String, keyword: String)] = [
        ("age", "进击的巨人"),      // AGE 动漫 - 经典动漫
        ("age", "鬼灭之刃"),        // AGE 动漫 - 热门动漫
        ("age", "咒术回战"),        // AGE 动漫 - 热门动漫
    ]
    
    /// 运行所有测试
    static func runAllTests() async {
        print("\n" + String(repeating: "=", count: 60))
        print("动漫源测试")
        print(String(repeating: "=", count: 60))
        
        for (source, keyword) in testCases {
            print("\n测试源: \(source), 关键词: \(keyword)")
            await testSource(source: source, keyword: keyword)
        }
        
        print("\n" + String(repeating: "=", count: 60))
        print("测试完成")
        print(String(repeating: "=", count: 60) + "\n")
    }
    
    /// 测试单个源
    static func testSource(source: String, keyword: String) async {
        // 这里需要实际调用 AnimeParser
        // 暂时只打印测试用例
        print("  - 跳过测试 (需要实际运行应用)")
    }
    
    /// 测试步骤说明
    static func printTestInstructions() {
        print("""
        
        ╔══════════════════════════════════════════════════════════╗
        ║              动漫源测试说明                              ║
        ╠══════════════════════════════════════════════════════════╣
        ║                                                          ║
        ║  1. 在应用中打开动漫探索页面                             ║
        ║  2. 使用以下关键词测试各个动漫源:                        ║
        ║                                                          ║
        ║  AGE 动漫 (age):                                         ║
        ║    - 进击的巨人 (经典动漫)                               ║
        ║    - 鬼灭之刃 (热门动漫)                                 ║
        ║    - 咒术回战 (热门动漫)                                 ║
        ║                                                          ║
        ║  3. 观察控制台日志输出:                                  ║
        ║    - HTML 长度应该 > 50KB                               ║
        ║    - 找到的元素数应该 > 0                               ║
        ║    - 应该有解析结果                                      ║
        ║                                                          ║
        ║  4. 如果仍然失败:                                        ║
        ║    - 检查网络连接                                        ║
        ║    - 检查网站是否可访问                                  ║
        ║    - 更新规则选择器                                      ║
        ║                                                          ║
        ╚══════════════════════════════════════════════════════════╝
        
        """)
    }
}
