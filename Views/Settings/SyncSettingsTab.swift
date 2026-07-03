import SwiftUI
import UniformTypeIdentifiers

struct SyncSettingsTab: View {
    @StateObject private var config = CloudSyncConfiguration.shared
    @StateObject private var syncService = CloudSyncService.shared

    @State private var showDirectoryPicker = false
    @State private var isTestingConnection = false
    @State private var testConnectionResult: String?

    var body: some View {
        MacSettingsForm {
            // MARK: 启用同步
            MacSettingsSection(header: t("sync.enable")) {
                MacSettingsRow(
                    title: t("sync.enable"),
                    subtitle: ""
                ) {
                    Toggle(isOn: $config.isEnabled) { EmptyView() }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            // MARK: 同步模式选择
            MacSettingsSection(header: t("sync.mode")) {
                Picker(t("sync.mode"), selection: $config.syncMode) {
                    Text(t("sync.mode.local")).tag(CloudSyncMode.localFolder)
                    Text(t("sync.mode.webdav")).tag(CloudSyncMode.webDAV)
                }
                .pickerStyle(.radioGroup)
            }

            if config.syncMode == .localFolder {
                // MARK: 本地文件夹
                localFolderSection
            } else {
                // MARK: WebDAV
                webDAVSection
            }

            // MARK: 冲突策略
            MacSettingsSection(header: t("sync.mode")) {
                Picker("", selection: $config.conflictStrategy) {
                    ForEach(CloudSyncConflictStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .pickerStyle(.radioGroup)

                if config.conflictStrategy == .localPreferred {
                    Text("以本设备数据为准，云端数据将被覆盖。推荐用于主力设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("以云端数据为准，本设备数据将被覆盖。推荐用于新设备首次同步。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: 同步操作
            if config.isEnabled {
                MacSettingsSection(header: "同步操作") {
                    MacSettingsRow(
                        title: t("sync.syncNow"),
                        subtitle: ""
                    ) {
                        Button {
                            Task { await syncService.sync() }
                        } label: {
                            if syncService.isSyncing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .controlSize(.small)
                            } else {
                                Text(t("sync.syncNow"))
                            }
                        }
                        .disabled(!config.isEnabled || syncService.isSyncing)
                    }

                    MacSettingsRow(
                        title: t("sync.restore"),
                        subtitle: ""
                    ) {
                        Button {
                            Task { await syncService.restoreFromCloud() }
                        } label: {
                            if syncService.isSyncing {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .controlSize(.small)
                            } else {
                                Text(t("sync.restore"))
                            }
                        }
                        .disabled(!config.isEnabled || syncService.isSyncing)
                    }
                }
            }

            // MARK: 同步状态
            if config.lastSyncedAt != nil || syncService.isSyncing || syncService.lastError != nil {
                MacSettingsSection(header: t("sync.progress")) {
                    if let lastSyncedAt = config.lastSyncedAt {
                        MacSettingsRow(
                            title: t("sync.lastSync"),
                            subtitle: ""
                        ) {
                            Text(lastSyncedAt, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if syncService.isSyncing {
                        MacSettingsRow(
                            title: t("sync.progress"),
                            subtitle: syncService.syncStatusMessage
                        ) {
                            ProgressView(value: syncService.syncProgress)
                                .frame(width: 120)
                        }
                    }

                    if let error = syncService.lastError {
                        MacSettingsRow(
                            title: t("sync.error"),
                            subtitle: error.localizedDescription
                        ) {
                            Button("清除") {
                                syncService.clearError()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 本地文件夹配置

    @ViewBuilder
    private var localFolderSection: some View {
        MacSettingsSection(header: t("sync.folder")) {
            MacSettingsRow(
                title: t("sync.folder"),
                subtitle: config.syncDirectoryURL?.path ?? t("general")
            ) {
                Button(config.syncDirectoryURL != nil ? "更改..." : "选择...") {
                    showDirectoryPicker = true
                }
                .fileImporter(
                    isPresented: $showDirectoryPicker,
                    allowedContentTypes: [.folder],
                    onCompletion: { result in
                        switch result {
                        case .success(let url):
                            config.syncDirectoryURL = url
                        case .failure:
                            break
                        }
                    }
                )
            }

            if config.syncDirectoryURL != nil {
                MacSettingsRow(
                    title: t("general"),
                    subtitle: ""
                ) {
                    Button("移除", role: .destructive) {
                        config.syncDirectoryURL = nil
                    }
                }
            }
        }
    }

    // MARK: - WebDAV 配置

    @ViewBuilder
    private var webDAVSection: some View {
        MacSettingsSection(header: t("sync.mode.webdav")) {
            MacSettingsRow(
                title: t("sync.webdav.url"),
                subtitle: "例如 https://nas.local:5006/webdav"
            ) {
                TextField(t("sync.webdav.url"), text: $config.webDAVURLString)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
            }

            MacSettingsRow(
                title: t("sync.webdav.username"),
                subtitle: ""
            ) {
                TextField(t("sync.webdav.username"), text: $config.webDAVUsername)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            MacSettingsRow(
                title: t("sync.webdav.password"),
                subtitle: ""
            ) {
                SecureField(t("sync.webdav.password"), text: $config.webDAVPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            MacSettingsRow(
                title: t("sync.webdav.test"),
                subtitle: testConnectionResult ?? ""
            ) {
                Button(t("sync.webdav.test")) {
                    Task { await testWebDAVConnection() }
                }
                .disabled(isTestingConnection || !hasValidWebDAVConfig)
            }
        }
    }

    private var hasValidWebDAVConfig: Bool {
        !config.webDAVURLString.isEmpty &&
        !config.webDAVUsername.isEmpty &&
        !config.webDAVPassword.isEmpty
    }

    private func testWebDAVConnection() async {
        guard let credentials = config.webDAVCredentials else {
            testConnectionResult = "请填写完整的连接信息"
            return
        }

        isTestingConnection = true
        testConnectionResult = nil

        do {
            _ = try await CloudSyncWebDAVClient.shared.propFind(
                url: credentials.baseURL,
                credentials: credentials,
                depth: 0
            )
            testConnectionResult = "连接成功 ✅"
        } catch {
            testConnectionResult = "连接失败: \(error.localizedDescription)"
        }

        isTestingConnection = false
    }
}
