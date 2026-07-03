import Foundation

/// 冲突解决器：根据策略处理记录级别和时间戳比较
enum CloudSyncConflictResolver {

    /// 记录冲突解决结果
    enum Resolution {
        /// 使用本地版本（忽略云端）
        case useLocal
        /// 使用云端版本（覆盖本地）
        case useCloud
        /// 两边都没有变化，跳过
        case skip
    }

    /// 文件冲突解决结果
    enum FileResolution {
        /// 上传本地文件
        case upload
        /// 下载云端文件
        case download
        /// 跳过（两边文件相同）
        case skip
    }

    // MARK: - 记录冲突解决

    /// 解决两条记录的冲突
    /// - Parameters:
    ///   - localUpdatedAt: 本地记录的 updatedAt
    ///   - cloudUpdatedAt: 云端记录的 updatedAt
    ///   - localIsDeleted: 本地是否标记删除
    ///   - cloudIsDeleted: 云端是否标记删除
    ///   - strategy: 用户选择的策略
    /// - Returns: 决议结果
    static func resolveRecord(
        localUpdatedAt: Date,
        cloudUpdatedAt: Date,
        localIsDeleted: Bool = false,
        cloudIsDeleted: Bool = false,
        strategy: CloudSyncConflictStrategy
    ) -> Resolution {
        // 两边都删除 → 跳过
        if localIsDeleted && cloudIsDeleted { return .skip }

        switch strategy {
        case .localPreferred:
            // 本地删除 → 传播删除
            if localIsDeleted { return .useLocal }
            // 云端删除且本地时间更晚 → 保留本地
            if cloudIsDeleted && localUpdatedAt >= cloudUpdatedAt { return .useLocal }
            // 云端删除且更晚 → 同步删除
            if cloudIsDeleted && cloudUpdatedAt > localUpdatedAt { return .useCloud }
            // 本地更新 → 上传
            if localUpdatedAt >= cloudUpdatedAt { return .useLocal }
            // 云端更新 → 下载
            return .useCloud

        case .cloudPreferred:
            // 云端删除 → 传播删除
            if cloudIsDeleted { return .useCloud }
            // 本地删除 → 恢复云端版本
            if localIsDeleted { return .useCloud }
            // 云端更新 → 下载
            if cloudUpdatedAt >= localUpdatedAt { return .useCloud }
            // 本地更新 → 上传
            return .useLocal
        }
    }

    // MARK: - 文件冲突解决

    /// 解决文件冲突
    /// - Parameters:
    ///   - localHash: 本地文件 hash（nil = 本地不存在）
    ///   - cloudHash: 云端文件 hash（nil = 云端不存在）
    ///   - strategy: 用户策略
    /// - Returns: 决议结果
    static func resolveFile(
        localHash: String?,
        cloudHash: String?,
        strategy: CloudSyncConflictStrategy
    ) -> FileResolution {
        switch (localHash, cloudHash) {
        case (nil, nil):
            return .skip

        case (.some, nil):
            // 只在本地存在 → 上传
            return .upload

        case (nil, .some):
            // 只在云端存在 → 下载
            return .download

        case (.some(let local), .some(let cloud)):
            if local == cloud {
                // hash 相同 → 跳过
                return .skip
            }
            // hash 不同 → 按策略决定
            switch strategy {
            case .localPreferred:
                return .upload
            case .cloudPreferred:
                return .download
            }
        }
    }

    // MARK: - 整份数据冲突解决

    /// 解决整份数据的冲突（设置、GridOrder 等）
    /// - Parameters:
    ///   - localDate: 本地上次修改时间
    ///   - cloudDate: 云端的 syncedAt
    ///   - strategy: 用户策略
    /// - Returns: true = 使用本地，false = 使用云端
    static func resolveWholeData(
        localDate: Date?,
        cloudDate: Date?,
        strategy: CloudSyncConflictStrategy
    ) -> Bool {
        switch strategy {
        case .localPreferred:
            return true
        case .cloudPreferred:
            return false
        }
    }
}
