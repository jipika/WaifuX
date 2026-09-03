import SwiftUI

/// Wallhaven 设置标签：API Key 绑定和默认浏览筛选。
struct WallhavenSettingsTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    private var apiKeyBinding: Binding<String> {
        Binding(get: { viewModel.apiKey }, set: { viewModel.apiKey = $0 })
    }

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: t("apiKey")) {
                HStack(spacing: 12) {
                    Text(t("apiKey"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer()

                    TextField(t("api.key.placeholder"), text: apiKeyBinding)
                        .font(.system(size: 12, weight: .regular))
                        .textFieldStyle(.plain)
                        .frame(width: 200)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                                )
                        )
                        .foregroundStyle(Color.white.opacity(0.85))

                    Link(destination: URL(string: "https://wallhaven.cc/settings/account")!) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(hex: "0A84FF").opacity(0.7))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Text(t("apiKeyDescription"))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            MacSettingsSection(header: t("wallhavenDisplayPreferences")) {
                MacSettingsRow(
                    title: t("wallhavenHidePortraitByDefault"),
                    subtitle: t("wallhavenHidePortraitByDefaultDesc"),
                    showDivider: true
                ) {
                    MacToggle(isOn: $viewModel.hidePortraitWallpapersByDefault)
                }

                MacSettingsRow(
                    title: t("wallhavenHidePeopleByDefault"),
                    subtitle: t("wallhavenHidePeopleByDefaultDesc"),
                    showDivider: false
                ) {
                    MacToggle(isOn: $viewModel.hidePeopleWallpapersByDefault)
                }
            }
        }
    }
}
