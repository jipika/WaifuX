import SwiftUI
import ServiceManagement

struct BackgroundAgentConnectionBanner: View {
    @ObservedObject private var helper = BackgroundAgentClient.shared
    var body: some View {
        if helper.isRelinkingRegistration {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(t("helper.repairing")).font(.callout).lineLimit(3)
                Spacer()
            }
            .padding(12)
            .background(.regularMaterial)
        } else if let error = helper.lastError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(error).font(.callout).lineLimit(3)
                Spacer()
                if helper.canRelinkRegistration {
                    // 只重建 WaifuX 自己的后台服务记录，不清理系统里其他 App 的登录项。
                    Button(t("helper.repair")) { helper.repairRegistration() }
                        .buttonStyle(.borderedProminent)
                }
                if helper.requiresApproval {
                    Button(t("settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                Button(t("retry")) { helper.retryConnection() }
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }
}
