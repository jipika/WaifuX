import Foundation
import LocalAuthentication
import AppKit

/// 文件夹加密锁定服务
/// - 支持生物识别（Touch ID）或锁屏密码验证
/// - 追踪当前已解锁的文件夹
/// - 主窗口关闭时自动重新锁定所有文件夹
@MainActor
final class FolderLockService: ObservableObject {
    static let shared = FolderLockService()

    /// 当前已解锁的文件夹 ID 集合
    @Published private(set) var unlockedFolderIDs = Set<String>()

    /// 是否正在认证中
    @Published private(set) var isAuthenticating = false

    private init() {}

    // MARK: - 公共 API

    /// 检查文件夹是否已解锁
    func isFolderUnlocked(_ folderID: String) -> Bool {
        unlockedFolderIDs.contains(folderID)
    }

    /// 尝试解锁文件夹，返回是否成功
    func unlockFolder(folderID: String, reason: String) async -> Bool {
        guard !unlockedFolderIDs.contains(folderID) else { return true }

        isAuthenticating = true
        defer { isAuthenticating = false }

        let success = await authenticate(reason: reason)
        if success {
            unlockedFolderIDs.insert(folderID)
        }
        return success
    }

    /// 锁定指定文件夹
    func lockFolder(_ folderID: String) {
        unlockedFolderIDs.remove(folderID)
    }

    /// 锁定所有文件夹
    func lockAllFolders() {
        unlockedFolderIDs.removeAll()
    }

    /// 锁定除指定 ID 外的所有文件夹
    func lockAllFolders(except folderID: String) {
        unlockedFolderIDs = [folderID]
    }

    // MARK: - 认证

    /// 系统级生物识别/密码认证
    /// 有 Touch ID / Face ID 时优先使用，否则回退到锁屏密码
    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = LocalizationService.shared.t("输入密码")

        var error: NSError?

        // 检查是否支持生物识别
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        let policy: LAPolicy
        if canEvaluate {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else {
            // 不支持生物识别，回退到设备密码
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                print("[FolderLock] 设备不支持任何认证方式: \(error?.localizedDescription ?? "未知")")
                return false
            }
            policy = .deviceOwnerAuthentication
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, authError in
                DispatchQueue.main.async {
                    if success {
                        print("[FolderLock] ✅ 认证成功")
                    } else {
                        print("[FolderLock] ❌ 认证失败: \(authError?.localizedDescription ?? "未知")")
                    }
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
