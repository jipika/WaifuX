import SwiftUI
import ServiceManagement

struct BackgroundAgentConnectionBanner: View {
    @ObservedObject private var helper = BackgroundAgentClient.shared
    var body: some View {
        if let error = helper.lastError {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                Text(error).font(.callout).lineLimit(3)
                Spacer()
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
