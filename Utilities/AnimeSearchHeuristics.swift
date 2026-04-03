import Foundation

/// 与 Kazumi 对齐：其规则仅依赖 XPath，不做「标题与关键词」启发式过滤。
/// WallHaven 额外过滤在**中日韩无空格检索**时易误杀（Bangumi 标题与站点标题常不一致）。
enum AnimeSearchHeuristics {

    /// 仅对明显为拉丁语系分词检索应用严格关键词匹配；CJK 检索保留站点返回的原始结果。
    static func shouldApplyStrictTitleKeywordFilter(searchQuery: String?) -> Bool {
        guard let q = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
            return false
        }
        return q.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
    }
}
