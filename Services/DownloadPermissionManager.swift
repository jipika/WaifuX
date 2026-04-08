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
    
    // MARK: - Properties
    private(set) var currentFolderURL: URL?
    /// 是否已尝试恢复路径（防止重复恢复）
    private var hasAttemptedRestore = false
    
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
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("WallHaven", isDirectory: true) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/WallHaven")
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
    
    /// 请求下载文件夹权限
    /// - Returns: 授权的文件夹URL，如果用户取消则返回nil
    @discardableResult
    func requestDownloadPermission() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "请选择壁纸保存位置"
        panel.prompt = "选择文件夹"
        
        // 预选之前的目录
        if let currentPath = currentFolderURL?.path {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        
        let response = await panel.begin()
        
        guard response == .OK, let selectedURL = panel.url else {
            return nil
        }
        
        savePath(for: selectedURL)
        return selectedURL
    }
    
    /// 获取下载文件夹URL
    /// - Parameter requestIfNeeded: 如果没有权限是否请求
    /// - Returns: 下载文件夹URL
    func getDownloadFolder(requestIfNeeded: Bool = true) async -> URL? {
        // 如果已经有有效的权限，直接返回
        if let url = currentFolderURL, hasValidPermission {
            return url
        }
        
        // 尝试确保目录存在后再次检查
        if let url = currentFolderURL, ensureDirectoryExists(at: url) {
            return url
        }
        
        // 如果需要请求权限
        if requestIfNeeded {
            return await requestDownloadPermission()
        }
        
        return nil
    }
    
    /// 确保有下载权限
    /// - Returns: 是否有有效权限
    func ensurePermission() async -> Bool {
        if hasValidPermission {
            return true
        }
        
        // 尝试创建目录
        if let url = currentFolderURL, ensureDirectoryExists(at: url) {
            return true
        }
        
        // 请求新权限
        if let _ = await requestDownloadPermission() {
            return hasValidPermission
        }
        
        return false
    }
    
    /// 开始访问安全作用域资源（无沙箱版本：空操作，始终成功）
    @discardableResult
    func startAccessingSecurityScope() -> Bool {
        // 无沙箱不需要安全作用域，直接返回 true
        return true
    }
    
    /// 停止访问安全作用域资源（无沙箱版本：空操作）
    func stopAccessingSecurityScope() {
        // 无沙箱不需要安全作用域管理
    }
    
    /// 清除保存的路径
    func clearPermission() {
        UserDefaults.standard.removeObject(forKey: folderPathKey)
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
