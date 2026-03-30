# WallHaven App Store 上架指南

## 上架前检查清单

### 1. 必要配置 ✅ 已完成

- [x] **Bundle Identifier**: `com.wallhaven.app` - 需要在 Apple Developer Portal 创建
- [x] **App Icon**: 已生成 Neo-Brutalist 风格图标，包含所有必需尺寸
- [x] **Info.plist**: 已配置所有必需字段和隐私描述
- [x] **Entitlements**: 已启用沙盒、网络客户端、文件读写权限
- [x] **Marketing Version**: 1.0.0
- [x] **Build Version**: 1

### 2. Apple Developer Portal 准备工作

#### 2.1 创建 App ID
1. 登录 [Apple Developer Portal](https://developer.apple.com)
2. 进入 Certificates, Identifiers & Profiles
3. 创建新的 App ID:
   - Platform: **macOS**
   - Bundle ID: **com.wallhaven.app**
   - Description: **WallHaven**
   - Capabilities: 勾选
     - [x] App Sandbox
     - [x] Network Client (Outgoing Connections)

#### 2.2 创建证书
1. **Development Certificate**: 用于本地调试
2. **Distribution Certificate**: 用于提交 App Store
3. **Developer ID Certificate**: 如需签名给非沙盒环境使用

#### 2.3 创建 Provisioning Profile
1. 创建 **Mac App Store** 类型的配置文件
2. 选择 App ID: `com.wallhaven.app`
3. 选择证书
4. 下载并导入到 Xcode

### 3. Xcode 配置

#### 3.1 签名配置
1. 打开项目设置
2. Signing & Capabilities:
   - 勾选 **Automatically manage signing**
   - Team: 选择你的开发团队
3. 或者手动配置:
   - Distribution Certificate
   - Mac App Store Provisioning Profile

#### 3.2 验证构建
```bash
# 在项目目录执行
xcodebuild -project WallHaven.xcodeproj -scheme WallHaven \
  -configuration Release \
  -allowProvisioningUpdates \
  build
```

### 4. 隐私与合规

#### 4.1 隐私描述 ✅ 已配置
- `NSDesktopFolderUsageDescription`: 下载文件夹访问说明
- `NSDocumentsFolderUsageDescription`: 文档文件夹访问说明

#### 4.2 潜在审核风险点

| 功能 | 风险等级 | 说明 | 处理方式 |
|------|----------|------|----------|
| 网络请求 | ⚠️ 中 | 访问 wallhaven.cc API | 已在 entitlements 启用 network.client |
| 外部链接 | ✅ 低 | "Visit Website" 按钮打开浏览器 | 符合 App Store 规范 |
| 文件下载 | ✅ 低 | 保存到用户 Downloads | 已启用 downloads.read-write |
| NSSharingServicePicker | ✅ 低 | 分享功能 | 标准 macOS API |
| NSPasteboard | ✅ 低 | 复制链接 | 标准 macOS API |

#### 4.3 内容分级
在 App Store Connect 中设置:
- **Category**: Utilities
- **Content Rating**: 4+ (轻微或无成人内容)
- 如显示 NSFW 内容，需设置为 17+

### 5. App Store Connect 配置

#### 5.1 创建 App
1. 登录 [App Store Connect](https://appstoreconnect.apple.com)
2. My Apps → + → New App
3. 填写信息:
   - Platforms: **macOS**
   - Name: **WallHaven**
   - Primary Language: **English** 或 **Chinese (Simplified)**
   - Bundle ID: **com.wallhaven.app**
   - SKU: **wallhaven-app-1**

#### 5.2 App 信息
- **Description**: 描述应用功能
- **Keywords**: wallpaper, desktop, images, photos, wallhaven
- **Marketing URL**: (可选) 应用网站
- **Support URL**: wallhaven.cc
- **Privacy Policy URL**: (可选)

#### 5.3 上传构建
1. Xcode → Product → Archive
2. 在 Organizer 中选择构建
3. 点击 Distribute App
4. 选择 App Store Connect
5. 上传构建

### 6. 审核注意事项

#### 6.1 常见拒绝原因
1. **功能不完整**: 确保所有按钮有实际功能
2. **崩溃问题**: 测试环境下充分测试
3. **隐私政策缺失**: 添加隐私政策页面
4. **截图不符合要求**: 提供正确的 Mac 应用截图

#### 6.2 截图要求
- 至少需要 1 张截图
- 尺寸: 1280x720 像素 (最小)
- 格式: PNG 或 JPG
- 建议: 1920x1080

#### 6.3 审核时长
- 正常: 1-3 工作日
- 复杂应用: 可能需要 7 天

### 7. 上架后检查

- [ ] TestFlight 测试 (可选内部测试)
- [ ] 监控 App Store Connect 审核状态
- [ ] 审核通过后检查 App Store 页面
- [ ] 确认版本号正确显示

---

## 快速检查表

在提交审核前，确保以下全部完成:

```
□ Apple Developer Portal: App ID 已创建
□ Apple Developer Portal: 证书已生成
□ Apple Developer Portal: Provisioning Profile 已创建
□ Xcode: 签名配置正确
□ Xcode: Archive 构建成功
□ App Store Connect: App 信息已填写
□ App Store Connect: 截图已上传
□ App Store Connect: 构建版本已选择
□ App Store Connect: 提交审核
```

---

## 联系支持

- Apple Developer Support: https://developer.apple.com/contact/
- App Store Connect Help: https://help.apple.com/app-store-connect/
