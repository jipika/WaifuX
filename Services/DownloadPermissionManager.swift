import Foundation
import AppKit

/// 下载权限管理器 - 使用安全作用域书签持久化文件夹访问权限
/// 解决每次下载都需要重新请求权限的问题
@MainActor
final class DownloadPermissionManager {
    static let shared = DownloadPermissionManager()
    
    // MARK: - UserDefaults Keys
    private let bookmarkKey = "download_folder_bookmark"
    private let folderPathKey = "download_folder_path"
    
    // MARK: - Properties
    private(set) var currentFolderURL: URL?
    private var bookmarkData: Data?
    /// 是否已尝试恢复书签（防止重复恢复）
    private var hasAttemptedRestore = false
    
    // MARK: - Initialization
    private init() {
        // ⚠️ 不在 init 中读取 UserDefaults 或调用 restoreFromBookmark！
        // 这会导致 _CFXPreferences 递归栈溢出崩溃。
        // 书签恢复延迟到 launch 后异步执行。
        
        // 仅设置默认路径作为占位符
        self.currentFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("WallHaven", isDirectory: true)
    }
    
    // MARK: - 延迟恢复（启动后调用）
    /// 异步恢复保存的书签权限。必须在 applicationDidFinishLaunching 之后调用，
    /// 避免在单例 init 中同步读取 UserDefaults 导致递归栈溢出。
    func restoreSavedPermission() {
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            print("[DownloadPermissionManager] No saved bookmark, using default path")
            return
        }

        self.bookmarkData = bookmark

        if let restoredURL = restoreFromBookmark() {
            self.currentFolderURL = restoredURL
            print("[DownloadPermissionManager] ✅ Successfully restored security scope on launch for: \(restoredURL.path)")
        } else {
            print("[DownloadPermissionManager] ⚠️ Bookmark restoration failed, will re-prompt user")
        }
    }
    
    // MARK: - Public Methods
    
    /// 检查是否有有效的下载权限
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
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        
        let response = await panel.begin()
        
        guard response == .OK, let selectedURL = panel.url else {
            return nil
        }
        
        // 保存书签
        saveBookmark(for: selectedURL)
        
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
        
        // 尝试从书签恢复权限
        if let url = restoreFromBookmark(), hasValidPermission {
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
        
        // 尝试从书签恢复
        if let _ = restoreFromBookmark(), hasValidPermission {
            return true
        }
        
        // 请求新权限
        if let _ = await requestDownloadPermission() {
            return hasValidPermission
        }
        
        return false
    }
    
    /// 开始访问安全作用域资源
    /// - Returns: 是否成功开始访问
    @discardableResult
    func startAccessingSecurityScope() -> Bool {
        guard let url = currentFolderURL else { return false }
        
        // 如果已经有权限，直接返回
        if FileManager.default.isWritableFile(atPath: url.path) {
            return true
        }
        
        // 尝试从书签恢复
        if restoreFromBookmark() != nil {
            return true
        }
        
        return false
    }
    
    /// 停止访问安全作用域资源
    func stopAccessingSecurityScope() {
        // 安全作用域访问会在应用退出时自动停止
        // 这里不需要显式调用 stopAccessingSecurityScopedResource
    }
    
    /// 清除保存的权限
    func clearPermission() {
        bookmarkData = nil
        currentFolderURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: folderPathKey)
    }
    
    // MARK: - Private Methods
    
    /// 保存书签
    private func saveBookmark(for url: URL) {
        do {
            // 创建安全作用域书签
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            self.bookmarkData = bookmark
            self.currentFolderURL = url
            
            // 保存到 UserDefaults
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(url.path, forKey: folderPathKey)
            
            print("[DownloadPermissionManager] Bookmark saved for: \(url.path)")
        } catch {
            print("[DownloadPermissionManager] Failed to create bookmark: \(error)")
        }
    }
    
    /// 从书签恢复
    private func restoreFromBookmark() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }
        
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                print("[DownloadPermissionManager] Bookmark is stale, need to re-request")
                clearPermission()
                return nil
            }
            
            // 开始访问安全作用域
            let didStartAccess = url.startAccessingSecurityScopedResource()
            
            if didStartAccess {
                self.bookmarkData = bookmark
                self.currentFolderURL = url
                print("[DownloadPermissionManager] Restored access to: \(url.path)")
                return url
            } else {
                print("[DownloadPermissionManager] Failed to start accessing security scope")
                return nil
            }
        } catch {
            print("[DownloadPermissionManager] Failed to resolve bookmark: \(error)")
            return nil
        }
    }
}
