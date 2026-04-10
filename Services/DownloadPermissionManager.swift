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
    
    // MARK: - 权限检查（启动时调用）
    
    /// 检查并请求下载目录权限（应用启动时调用）
    /// - Returns: 是否已有权限或成功获取权限
    @discardableResult
    func checkAndRequestPermissionOnLaunch() async -> Bool {
        // 首先尝试静默检查是否已有权限
        if await checkSilentPermission() {
            print("[DownloadPermissionManager] ✅ Already has download folder access")
            return true
        }
        
        // 检查是否已经请求过权限（避免重复打扰用户）
        let alreadyRequested = UserDefaults.standard.bool(forKey: permissionRequestedKey)
        
        if !alreadyRequested {
            // 首次启动，记录已请求
            UserDefaults.standard.set(true, forKey: permissionRequestedKey)
        }
        
        // 显示权限提示对话框
        return await showPermissionAlertAndRequest()
    }
    
    /// 静默检查是否有下载目录权限（不触发系统弹窗）
    private func checkSilentPermission() async -> Bool {
        guard let url = currentFolderURL else { return false }
        
        // 尝试静默访问 - 使用 access 系统调用检查权限
        let path = url.path
        let result = await Task.detached {
            // 尝试创建测试文件来验证写入权限
            let testFile = path + ".write_test_" + UUID().uuidString
            let created = FileManager.default.createFile(atPath: testFile, contents: Data(), attributes: nil)
            if created {
                try? FileManager.default.removeItem(atPath: testFile)
            }
            return created
        }.value
        
        return result
    }
    
    /// 显示权限提示并请求
    private func showPermissionAlertAndRequest() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "需要下载文件夹权限"
        alert.informativeText = "WallHaven 需要访问您的下载文件夹来保存壁纸和媒体文件。请在接下来的对话框中选择允许访问。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "稍后设置")
        
        let response = await MainActor.run {
            alert.runModal()
        }
        
        guard response == .alertFirstButtonReturn else {
            print("[DownloadPermissionManager] User postponed permission request")
            return false
        }
        
        // 打开文件选择器让用户授权
        return await requestDownloadPermissionWithOpenPanel()
    }
    
    /// 使用 OpenPanel 请求权限（这会触发系统 TCC 提示）
    @discardableResult
    private func requestDownloadPermissionWithOpenPanel() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "请选择下载文件夹以授权 WallHaven 访问"
        panel.prompt = "允许访问"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        
        let response = await panel.begin()
        
        guard response == .OK, let selectedURL = panel.url else {
            print("[DownloadPermissionManager] User cancelled permission request")
            return false
        }
        
        // 验证选中的路径确实是 Downloads 或其子目录
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let isInDownloads = selectedURL.path.hasPrefix(downloadsURL?.path ?? "")
        
        if isInDownloads {
            savePath(for: selectedURL)
            print("[DownloadPermissionManager] ✅ Permission granted for: \(selectedURL.path)")
            onPermissionStatusChanged?(true)
            return true
        } else {
            // 用户选择了其他位置，仍然允许但记录为自定义路径
            savePath(for: selectedURL)
            print("[DownloadPermissionManager] ✅ Custom path selected: \(selectedURL.path)")
            onPermissionStatusChanged?(true)
            return true
        }
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
    
    /// 确保有下载权限（无沙箱版本：直接创建目录并返回）
    /// - Returns: 是否有有效权限（无沙箱下始终返回 true）
    func ensurePermission() async -> Bool {
        // 无沙箱模式：不需要权限弹窗，确保目录存在即可
        if let url = currentFolderURL {
            ensureDirectoryExists(at: url)
        }
        return true
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
