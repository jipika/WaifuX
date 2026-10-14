// 回归守卫：孤儿 folderID 归零的纯函数语义（clearOrphanFolderMemberships）。
// 运行: swiftc -parse-as-library -o /tmp/orphan_test OrphanFolderMembershipRegression.swift && /tmp/orphan_test
// 纯函数验证的 top-level 文件必须叫 main.swift —— 这里用 @main 包装。
import Foundation

@main
struct OrphanFolderMembershipRegression {
    static func main() {
        run()
    }

    static func run() {
        // 从主源码同步的审计口径（LibraryFolderMembershipPolicy.audit）
        struct AuditShadow { let invalidCount: Int; let invalidIDs: Set<String> }
        func auditShadow(folderIDs: [String?], valid: Set<String>) -> AuditShadow {
            var count = 0; var ids = Set<String>()
            for id in folderIDs {
                guard let id else { continue }
                guard valid.contains(id) else { count += 1; ids.insert(id); continue }
            }
            return AuditShadow(invalidCount: count, invalidIDs: ids)
        }

        // 模拟 clearOrphanFolderMemberships 的核心循环与计数口径
        struct Record { var folderID: String? }
        func clearOrphans(_ records: inout [Record], valid: Set<String>) -> Int {
            guard !valid.isEmpty else { return -1 }
            var cleared = 0
            for i in records.indices {
                guard let f = records[i].folderID, !valid.contains(f) else { continue }
                records[i].folderID = nil
                cleared += 1
            }
            return cleared
        }

        var failed = false
        func check(_ name: String, _ cond: Bool) {
            if !cond { print("FAIL: \(name)"); failed = true } else { print("ok: \(name)") }
        }

        // 1. 混合归属：只清孤儿，计数=实际改写条数（不是孤儿 ID 去重数、不含原本 nil 的）
        var recs = [Record(folderID: "a"), Record(folderID: nil), Record(folderID: "ghost1"), Record(folderID: "ghost2"), Record(folderID: "ghost1")]
        let n = clearOrphans(&recs, valid: ["a"])
        check("改写条数=3（按条不按去重ID）", n == 3)
        check("孤儿全归零", recs.allSatisfy { $0.folderID != "ghost1" && $0.folderID != "ghost2" })
        check("有效保留", recs[0].folderID == "a")

        // 2. 幂等：再跑一次返回 0
        let n2 = clearOrphans(&recs, valid: ["a"])
        check("幂等：第二次返回0", n2 == 0)

        // 3. 空有效集合中止（防文件夹定义未加载时全量清空）
        var recs2 = [Record(folderID: "a"), Record(folderID: "b")]
        let n3 = clearOrphans(&recs2, valid: [])
        check("空集合中止返回-1", n3 == -1)
        check("中止时数据未动", recs2[0].folderID == "a" && recs2[1].folderID == "b")

        // 4. 审计口径对照：invalidCount 是记录条数而非去重 ID 数（3 条孤儿、2 个 ID）
        let a = auditShadow(folderIDs: ["g1", "g2", "g1"], valid: [])
        check("audit 计数按条", a.invalidCount == 3 && a.invalidIDs.count == 2)

        exit(failed ? 1 : 0)
    }
}
