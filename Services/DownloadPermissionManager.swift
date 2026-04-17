import Foundation
import AppKit

/// 下载权限管理器 - 无沙箱版本
/// 去掉 App Sandbox 后，不再需要 Security Scoped Bookmark 机制。
/// 直接使用文件系统访问，hasValidPermission 基于 FileManager 判断。
@MainActor
final class DownloadPermissionManager {
    static let shared = DownloadPermissionManager()
    
    // MARK: - UserDefaults Keys
    private let folderPathKey = "download_folder_path"
    private let permissionRequestedKey = "download_permission_requested"
    
    // MARK: - Properties
    private(set) var currentFolderURL: URL?
    /// 是否已尝试恢复路径（防止重复恢复）
    private var hasAttemptedRestore = false
    /// 权限状态回调
    var onPermissionStatusChanged: ((Bool) -> Void)?
    
    // MARK: - Initialization
    private init() {
        // ⚠️ 不在 init 中读取 UserDefaults！
        // 这会导致 _CFXPreferences 递归栈溢出崩溃。
        // 路径恢复延迟到 launch 后异步执行。
        
        // 仅设置默认路径作为占位符
        self.currentFolderURL = Self.defaultDownloadURL
    }
    
    // MARK: - 默认路径
    
    private static var defaultDownloadURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("WaifuX", isDirectory: true) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/WaifuX")
    }
    
    // MARK: - 延迟恢复（启动后调用）
    /// 恢复保存的下载路径。必须在 applicationDidFinishLaunching 之后调用，
    /// 避免在单例 init 中同步读取 UserDefaults 导致递归栈溢出。
    func restoreSavedPermission() {
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        
        if let savedPath = UserDefaults.standard.string(forKey: folderPathKey) {
            let url = URL(fileURLWithPath: savedPath)
            if FileManager.default.fileExists(atPath: url.path) {
                self.currentFolderURL = url
                print("[DownloadPermissionManager] ✅ Restored saved path: \(url.path)")
            } else {
                print("[DownloadPermissionManager] ⚠️ Saved path no longer exists: \(savedPath), resetting to default")
                resetToDefaultPath()
            }
        } else {
            print("[DownloadPermissionManager] No saved path, using default")
            resetToDefaultPath()
        }
    }
    
    /// 重置为默认下载路径
    private func resetToDefaultPath() {
        self.currentFolderURL = Self.defaultDownloadURL
        print("[DownloadPermissionManager] Reset to default path: \(self.currentFolderURL?.path ?? "unknown")")
    }
    
    // MARK: - Public Methods
    
    /// 检查是否有有效的下载权限（无沙箱版本：直接检查路径是否可写）
    var hasValidPermission: Bool {
        guard let url = currentFolderURL else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }
    
    /// 请求下载文件夹（用于用户手动更改存储位置）
    /// - Returns: 选择的文件夹URL，取消则返回nil
    @discardableResult
    func requestDownloadPermission() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "请选择壁纸和媒体的保存位置"
        panel.prompt = "选择文件夹"
        
        // 预选之前的目录
        if let currentPath = currentFolderURL?.path {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        }
        
        let response = await panel.begin()
        
        guard response == .OK, let selectedURL = panel.url else {
            return nil
        }
        
        savePath(for: selectedURL)
        return selectedURL
    }
    
    /// 获取下载文件夹URL（无沙箱版本：不弹窗）
    /// - Parameter requestIfNeeded: 如果没有路径是否请求（无沙箱下忽略，直接创建默认目录）
    /// - Returns: 下载文件夹URL（始终返回有效值）
    func getDownloadFolder(requestIfNeeded: Bool = true) async -> URL? {
        guard let url = currentFolderURL else { return nil }

        // 确保目录存在
        if !FileManager.default.fileExists(atPath: url.path) {
            ensureDirectoryExists(at: url)
        }
        return url
    }
    
    /// 确保存储目录存在
    /// - Returns: 目录是否可用
    func ensurePermission() async -> Bool {
        if let url = currentFolderURL {
            ensureDirectoryExists(at: url)
        }
        return true
    }
    
    /// 开始访问安全作用域资源（空操作，保留兼容性）
    @discardableResult
    func startAccessingSecurityScope() -> Bool { true }
    
    /// 停止访问安全作用域资源（空操作，保留兼容性）
    func stopAccessingSecurityScope() {}
    
    /// 清除保存的路径
    func clearPermission() {
        UserDefaults.standard.removeObject(forKey: folderPathKey)
        UserDefaults.standard.removeObject(forKey: permissionRequestedKey)
        resetToDefaultPath()
    }
    
    // MARK: - Private Methods
    
    /// 保存选择的路径
    private func savePath(for url: URL) {
        self.currentFolderURL = url
        UserDefaults.standard.set(url.path, forKey: folderPathKey)
        print("[DownloadPermissionManager] Path saved for: \(url.path)")
    }
    
    /// 确保目录存在，不存在则创建
    /// - Returns: 目录是否可用（已存在或创建成功）
    @discardableResult
    private func ensureDirectoryExists(at url: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                print("[DownloadPermissionManager] Created directory: \(url.path)")
                return true
            } catch {
                print("[DownloadPermissionManager] Failed to create directory: \(error)")
                return false
            }
        }
        return fm.isWritableFile(atPath: url.path)
    }
}
