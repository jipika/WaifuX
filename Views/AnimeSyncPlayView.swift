import SwiftUI

@MainActor
struct AnimeSyncPlayView: View {
    @ObservedObject private var service: AnimeSyncPlayService
    @State private var chatDraft = ""

    init(service: AnimeSyncPlayService) { self.service = service }

    private var hasSession: Bool {
        switch service.connectionState {
        case .disconnected, .failed: return false
        default: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(t("一起看"), systemImage: "person.2.wave.2")
                    .font(.headline)
                Spacer()
                Text(service.connectionState.label).foregroundStyle(.secondary)
                if service.roundTripMilliseconds > 0 {
                    Text("\(service.roundTripMilliseconds) ms").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(t("服务器"))
                    TextField("HOST:PORT", text: $service.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(t("Syncplay 服务器地址"))
                }
                GridRow {
                    Text(t("用户名"))
                    TextField(t("房间中显示的用户名"), text: $service.username).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(t("房间"))
                    TextField(t("与朋友使用相同房间名"), text: $service.room).textFieldStyle(.roundedBorder)
                }
            }
            .disabled(hasSession)
            HStack {
                Button(t("加入房间")) { service.connect() }
                    .disabled(hasSession)
                Button(t("创建房间")) { service.connect(createRoom: true) }
                    .disabled(hasSession)
                Spacer()
                Button(t("断开连接"), role: .destructive) { service.disconnect() }
                    .disabled(!hasSession)
            }
            Text(t("标准 Syncplay TCP 协议；房间不存在时服务器会创建。官方服务器使用 TLS，自建服务器可填写 syncplays://HOST:PORT 启用 STARTTLS。只共享番剧标题、集数和播放状态。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = service.error { Text(error).font(.callout).foregroundStyle(.red) }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(service.messages) { message in
                            HStack(alignment: .top, spacing: 8) {
                                if !message.isSystem {
                                    Text(message.username).fontWeight(.medium).foregroundStyle(.secondary)
                                }
                                Text(message.text)
                                    .foregroundStyle(message.isSystem ? Color.secondary : Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(message.isSystem ? .caption : .callout)
                            .id(message.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                .frame(minHeight: 120, idealHeight: 220)
                .onChange(of: service.messages.last?.id) {
                    if let id = service.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            HStack {
                TextField(t("向房间发送消息"), text: $chatDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendChat() }
                Button(t("发送")) { sendChat() }
                    .disabled(chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(service.connectionState != .connected)
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 540, minHeight: 390)
        // Closing this configuration sheet does not end a session; the VM disconnects when playback stops/exits.
    }

    private func sendChat() {
        guard service.connectionState == .connected else { return }
        service.sendChat(chatDraft)
        chatDraft = ""
    }
}
