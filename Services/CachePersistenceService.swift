import Foundation
import Cache

// MARK: - 基于 hyperoslo/Cache 的持久化服务

/// 替代 UserDefaults 存储大规模收藏/下载记录。
///
/// 存储布局 (所有 key 经过 MD5 哈希后落盘，由 Cache 库自动处理)：
/// ```
/// 个体记录:  {category}/{id}  → Data (单条 JSON)
/// 索引:      index/{category} → Data (JSON [String])
/// ```
///
/// 分类命名空间：
/// - `wallpaper/fav` — 壁纸收藏
/// - `wallpaper/dl`  — 壁纸下载
/// - `media/fav`     — 媒体收藏
/// - `media/dl`      — 媒体下载
/// - `anime/fav`     — 动漫收藏
@MainActor
final class CachePersistenceService {
    static let shared = CachePersistenceService()

    private let storage: Storage<String, Data>

    /// 缓存目录的磁盘路径（初始化时缓存，用于孤儿恢复扫描）
    private let storageDiskPath: String

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.waifux.app/CachePersistence")

        // DiskStorage.path = directory + "/" + name (与 hyperoslo/Cache DiskStorage 保持一致)
        storageDiskPath = appSupport.appendingPathComponent("Records", isDirectory: true).path

        let diskConfig = DiskConfig(
            name: "Records",
            expiry: .never,
            directory: appSupport
        )
        let memoryConfig = MemoryConfig(expiry: .never, countLimit: 0, totalCostLimit: 0)

        do {
            storage = try Storage<String, Data>(
                diskConfig: diskConfig,
                memoryConfig: memoryConfig,
                fileManager: .default,
                transformer: TransformerFactory.forData()
            )
        } catch {
            fatalError("[CachePersistenceService] Failed to initialize: \(error)")
        }
    }

    // MARK: - 个体记录

    /// 保存单条记录
    @discardableResult
    func save<T: Encodable>(_ value: T, key: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            try storage.setObject(data, forKey: key)
            return true
        } catch {
            print("[CachePersistenceService] Failed to save key=\(key): \(error)")
            return false
        }
    }

    /// 读取单条记录
    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        do {
            let data = try storage.object(forKey: key)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            return nil
        }
    }

    /// 删除单条记录
    @discardableResult
    func delete(key: String) -> Bool {
        do {
            try storage.removeObject(forKey: key)
            return true
        } catch {
            print("[CachePersistenceService] Failed to delete key=\(key): \(error)")
            return false
        }
    }

    /// 检查记录是否存在
    func exists(key: String) -> Bool {
        (try? storage.existsObject(forKey: key)) ?? false
    }

    // MARK: - 索引

    /// 保存分类下所有活跃 ID 索引
    @discardableResult
    func saveIndex(_ ids: [String], key: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(ids)
            try storage.setObject(data, forKey: key)
            return true
        } catch {
            print("[CachePersistenceService] Failed to save index key=\(key): \(error)")
            return false
        }
    }

    /// 读取分类下所有活跃 ID 索引
    func loadIndex(key: String) -> [String] {
        do {
            let data = try storage.object(forKey: key)
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            return []
        }
    }

    // MARK: - 批量操作

    /// 加载分类下所有记录（类型由返回类型推断）
    func loadAll<T: Decodable>(category: String) -> [T] {
        let ids = loadIndex(key: "index/\(category)")
        var results: [T] = []
        for id in ids {
            if let record: T = load(T.self, key: "\(category)/\(id)") {
                results.append(record)
            }
        }
        return results
    }

    /// 全量覆盖保存（用于迁移/批量重建）
    @discardableResult
    func saveAll<T: Encodable & Identifiable>(
        _ records: [T],
        category: String,
        activeFilter: ((T) -> Bool)? = nil
    ) -> Bool where T.ID == String {
        let filtered = activeFilter.map { records.filter($0) } ?? records
        for record in filtered {
            guard save(record, key: "\(category)/\(record.id)") else {
                return false
            }
        }
        let ids = filtered.map(\.id)
        return saveIndex(ids, key: "index/\(category)")
    }

    // MARK: - 孤儿记录恢复

    /// 扫描缓存目录，恢复不在索引中但文件存在的孤儿记录。
    ///
    /// 原理：遍历缓存目录下所有文件 → 排除已知索引文件 → 对每个未匹配文件解码 JSON 提取 `id`
    /// → 用 `MD5("{category}/{id}")` 计算期望的文件名 → 匹配则说明该记录属于此 category 但未被索引收录。
    ///
    /// - Parameter categories: 需要扫描的分类列表，如 `["media/dl", "media/fav"]`
    /// - Returns: 按分类分组的孤儿记录原始 JSON 数据（调用方负责解码为具体类型）
    func recoverOrphanedRecordData(for categories: [String]) -> [String: [Data]] {
        let fm = FileManager.default
        let dirPath = storageDiskPath

        guard let allFiles = try? fm.contentsOfDirectory(atPath: dirPath) else {
            return [:]
        }

        // 所有已知索引文件哈希（大写 MD5）
        var knownIndexHashes = Set<String>()
        for cat in categories {
            knownIndexHashes.insert(MD5("index/\(cat)"))
        }

        // 已知记录文件哈希：从索引反推
        var knownRecordHashes = Set<String>()
        for cat in categories {
            let ids = loadIndex(key: "index/\(cat)")
            for id in ids {
                knownRecordHashes.insert(MD5("\(cat)/\(id)"))
            }
        }

        var result: [String: [Data]] = [:]
        // 已被识别归属的文件，避免重复处理
        var matchedFiles = knownIndexHashes.union(knownRecordHashes)

        for fileName in allFiles {
            guard !matchedFiles.contains(fileName) else { continue }

            let filePath = "\(dirPath)/\(fileName)"
            guard fm.fileExists(atPath: filePath),
                  let fileData = fm.contents(atPath: filePath),
                  let json = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
                  let id = (json["id"] as? String)
                    ?? ((json["wallpaper"] as? [String: Any])?["id"] as? String)
                    ?? ((json["item"] as? [String: Any])?["id"] as? String)
            else { continue }

            // 尝试每个分类：MD5("{category}/{id}") 与文件名匹配即归属该分类
            for cat in categories {
                let expectedHash = MD5("\(cat)/\(id)")
                if expectedHash == fileName {
                    result[cat, default: []].append(fileData)
                    matchedFiles.insert(fileName)
                    break
                }
            }
        }

        return result
    }
}
