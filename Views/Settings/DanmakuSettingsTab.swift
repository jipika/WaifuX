import SwiftUI

/// 弹幕设置标签：弹弹play开放平台凭证（AppId/AppSecret）。
/// 开放 API 强制鉴权后，无凭证时播放器弹幕层会给出明确提示并停用网络请求。
struct DanmakuSettingsTab: View {
    @State private var appID: String = ""
    @State private var appSecret: String = ""
    @State private var savedMessage: String?
    @State private var source: DanmakuCredentials.Source = .none

    var body: some View {
        MacSettingsForm {
            MacSettingsSection(header: t("settings.danmaku.credentials")) {
                MacSettingsRow(
                    title: statusTitle,
                    subtitle: t("settings.danmaku.credentialsHint"),
                    showDivider: true
                ) {
                    if let url = URL(string: "https://dev.dandanplay.com") {
                        Link(destination: url) {
                            Text("dev.dandanplay.com")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                    }
                }

                MacSettingsRow(title: t("settings.danmaku.appID"), showDivider: true) {
                    TextField("AppId", text: $appID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 220)
                        .disableAutocorrection(true)
                }

                MacSettingsRow(title: t("settings.danmaku.appSecret"), showDivider: savedMessage == nil) {
                    SecureField("AppSecret", text: $appSecret)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 220)
                }

                if let savedMessage {
                    MacSettingsRow(title: savedMessage, showDivider: false) {
                        EmptyView()
                    }
                }
            }

            HStack(spacing: 10) {
                Button(t("settings.danmaku.save")) {
                    if DanmakuCredentials.saveUserCredentials(appID: appID, appSecret: appSecret) {
                        savedMessage = t("settings.danmaku.saved")
                        appSecret = ""
                        refreshSource()
                    } else {
                        savedMessage = t("settings.danmaku.saveFailed")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(t("settings.danmaku.clear")) {
                    DanmakuCredentials.saveUserCredentials(appID: "", appSecret: "")
                    appID = ""
                    appSecret = ""
                    savedMessage = t("settings.danmaku.cleared")
                    refreshSource()
                }
                .controlSize(.small)

                Spacer()
            }
            .padding(.top, -12)

            Text(t("settings.danmaku.credentialsHint"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.top, -12)
                .padding(.leading, 2)
        }
        .onAppear {
            appID = DanmakuCredentials.userSavedAppID() ?? ""
            refreshSource()
        }
    }

    private var statusTitle: String {
        switch source {
        case .environment: return t("settings.danmaku.sourceEnv")
        case .buildConfiguration: return t("settings.danmaku.sourceBuild")
        case .keychain: return t("settings.danmaku.sourceKeychain")
        case .none: return t("settings.danmaku.sourceNone")
        }
    }

    private func refreshSource() {
        source = DanmakuCredentials.activeSource
    }
}
