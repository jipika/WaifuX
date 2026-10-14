import SwiftUI

/// 「设置 → 通用」里的屏保区块（嵌入 GeneralSettingsTab，不再有独立标签）。
///
/// 行为与动态锁屏一致：安装组件后屏保**自动跟随当前桌面壁纸**——
/// 更换壁纸（含 Scene / Web 离线烘焙完成）后自动更新，不单独选壁纸。
/// macOS 仍要求在「系统设置 → 墙纸 → 屏幕保护程序」中手动选中 WaifuX 一次，
/// 这是系统限制。
///
/// 注意：body 直接输出多个 MacSettingsSection（外层 GeneralSettingsTab 的
/// MacSettingsForm 提供滚动容器），不要再包一层 MacSettingsForm。
struct ScreenSaverSettingsTab: View {
    @ObservedObject private var service = ScreenSaverService.shared

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            componentSection
            wallpaperSection
            notesSection
        }
        .glassAlert(
            t("screensaver"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            message: errorMessage ?? "",
            actions: [
                GlassAlertAction("OK", role: .cancel) { errorMessage = nil }
            ]
        )
        .onAppear { service.refreshConfiguredState() }
    }

    // MARK: - 组件

    private var componentSection: some View {
        MacSettingsSection(header: t("screensaver.component")) {
            MacSettingsRow(
                title: service.isInstalled ? t("screensaver.installed") : t("screensaver.notInstalled"),
                subtitle: isWorking ? t("screensaver.working") : nil
            ) {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Button(service.isInstalled ? t("screensaver.reinstall") : t("screensaver.install")) {
                        perform { try await service.install() }
                    }
                    .disabled(isWorking)
                    if service.isInstalled {
                        Button(t("screensaver.uninstall")) {
                            perform { try await service.uninstall() }
                        }
                        .disabled(isWorking)
                    }
                }
            }

            MacSettingsRow(
                title: t("screensaver.openSystemSettings"),
                showDivider: false
            ) {
                Button(t("screensaver.openSystemSettings")) {
                    service.openSystemSettings()
                }
                .disabled(!service.isInstalled)
            }

            Text(t("screensaver.componentFooter"))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    // MARK: - 跟随状态

    private var wallpaperSection: some View {
        MacSettingsSection(header: t("screensaver.wallpaper")) {
            MacInfoRow(
                title: t("screensaver.current"),
                value: service.configuredTitle ?? t("screensaver.none")
            )

            MacSettingsRow(
                title: t("screensaver.followTitle"),
                subtitle: t("screensaver.followSubtitle"),
                showDivider: false
            ) {
                Button(t("screensaver.syncNow")) {
                    isWorking = true
                    Task {
                        defer { isWorking = false }
                        do {
                            try await service.syncNow()
                            service.refreshConfiguredState()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(isWorking)
            }

            Text(t("screensaver.followFooter"))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    // MARK: - 说明

    private var notesSection: some View {
        MacSettingsSection(header: t("screensaver")) {
            Text(t("screensaver.runtimeFooter"))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Text(t("screensaver.mediaCacheInfo"))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    // MARK: - 动作

    @MainActor
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                try await action()
                service.refreshConfiguredState()
            } catch {
                service.refreshConfiguredState()
                errorMessage = error.localizedDescription
            }
        }
    }
}
