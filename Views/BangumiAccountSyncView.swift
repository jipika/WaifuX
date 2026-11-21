import SwiftUI

/// The host may inject one account service; opening this view performs no HTTP requests.
@MainActor
struct BangumiAccountSyncView: View {
    private let injectedService: BangumiAccountSync?
    @StateObject private var ownedService = BangumiAccountSync()

    init(service: BangumiAccountSync? = nil) { injectedService = service }

    var body: some View {
        BangumiAccountSyncForm(service: injectedService ?? ownedService)
    }
}

@MainActor
private struct BangumiAccountSyncForm: View {
    @ObservedObject var service: BangumiAccountSync
    @State private var tokenDraft = ""
    @State private var confirmingUpload = false

    init(service: BangumiAccountSync) { self.service = service }

    var body: some View {
        Form {
            Section(t("Bangumi 账号")) {
                if let user = service.user {
                    LabeledContent(t("当前账号"), value: user.nickname?.isEmpty == false ? "\(user.nickname!) (@\(user.username))" : "@\(user.username)")
                }
                Button(t("退出账号并删除 Token"), role: .destructive) {
                    tokenDraft = ""
                    Task { await service.signOut() }
                }
                .disabled(service.isBusy)
                SecureField("Personal Access Token", text: $tokenDraft)
                    .textContentType(.password)
                    .accessibilityLabel("Bangumi Personal Access Token")
                HStack {
                    Button(t("验证并保存 Token")) {
                        let candidate = tokenDraft
                        tokenDraft = ""
                        Task { await service.signIn(personalAccessToken: candidate) }
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.isBusy)
                    Button(t("验证已保存的账号")) { Task { await service.restoreAccount() } }
                        .disabled(service.isBusy)
                }
                Link(t("在 Bangumi 管理 Personal Access Token"), destination: URL(string: "https://next.bgm.tv/demo/access-token")!)
                Text(t("Token 仅保存在本机钥匙串。验证账号只读取用户信息，导入和上传由下方按钮单独执行。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(t("追番状态")) {
                Picker(t("冲突处理"), selection: $service.conflictPolicy) {
                    ForEach(BangumiSyncConflictPolicy.allCases) { policy in Text(policy.label).tag(policy) }
                }
                .disabled(service.isBusy)
                HStack {
                    Button(t("从 Bangumi 导入收藏与状态")) { Task { await service.importFromBangumi() } }
                    Button(t("上传本地追番状态…")) { confirmingUpload = true }
                }
                .disabled(service.user == nil || service.isBusy)
                Text(t("导入保留本地标题、封面、添加日期、备注、评分和标签；较新时间优先，同时间保留本地。上传只写入观看状态，不删除远端收藏。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service.isBusy { ProgressView(t("正在处理…")).controlSize(.small) }
            if let error = service.error {
                Text(error).foregroundStyle(.red).accessibilityLabel(String(format: t("错误：%@"), error))
            }
            if let report = service.report {
                Section(t("本次结果")) {
                    Text(report.summary)
                    if !report.failures.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                                    Text(failure).font(.caption).foregroundStyle(.orange)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 160)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 580, minHeight: 420)
        .confirmationDialog(t("上传本地追番状态到 Bangumi"), isPresented: $confirmingUpload, titleVisibility: .visible) {
            Button(t("上传状态")) { Task { await service.uploadLocalStatuses() } }
            Button(t("取消"), role: .cancel) {}
        } message: {
            Text(t("此操作会按所选冲突规则写入当前账号的远端追番状态。没有 Bangumi ID 的本地条目会跳过。"))
        }
        .onDisappear { tokenDraft = "" }
    }
}
