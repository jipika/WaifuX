import SwiftUI

/// 可用于全局下载 sheet，也可传入 animeId 嵌入番剧本地缓存页。
struct AnimeDownloadManagementView: View {
    let animeId: String?
    @ObservedObject private var engine = AnimeDownloadEngine.shared

    init(animeId: String? = nil) { self.animeId = animeId }

    private var tasks: [AnimeDownloadEngine.TaskState] {
        engine.tasksSorted.filter { animeId == nil || $0.animeId == animeId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("下载管理")).font(.title3.weight(.semibold))
                Spacer()
                Text("\(Int(engine.progress(forAnime: animeId) * 100))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: engine.progress(forAnime: animeId))
                .accessibilityLabel(t("总下载进度"))
            if let message = engine.persistenceError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if tasks.isEmpty {
                ContentUnavailableView(t("暂无下载任务"), systemImage: "arrow.down.circle")
            } else {
                List(tasks) { task in
                    AnimeDownloadManagementRow(task: task, engine: engine)
                        .padding(.vertical, 5)
                }
                .listStyle(.plain)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 300)
        .task { engine.restoreSavedTasks() }
    }
}

private struct AnimeDownloadManagementRow: View {
    let task: AnimeDownloadEngine.TaskState
    let engine: AnimeDownloadEngine

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.animeTitle).font(.headline).lineLimit(1)
                Text(task.episodeName ?? String(format: t("episode.number"), task.episodeNumber))
                    .font(.callout).lineLimit(1)
                HStack(spacing: 8) {
                    Text(task.sourceName)
                    Text(task.status.displayName)
                    Text("\(Int(task.progress * 100))%")
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(1, max(0, task.progress)))
                if task.downloadedBytes > 0 {
                    Text(byteProgress).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let message = task.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if task.status.isActive {
                    Button { engine.pauseByRecordID(task.id) } label: {
                        Label(t("暂停"), systemImage: "pause.fill")
                    }
                } else if task.status.canResume {
                    Button {
                        if task.status == .failed { engine.retryByRecordID(task.id) }
                        else { engine.resumeByRecordID(task.id) }
                    } label: {
                        Label(task.status == .failed ? t("重试") : t("恢复"),
                              systemImage: task.status == .failed ? "arrow.clockwise" : "play.fill")
                    }
                }
                if task.status != .completed && task.status != .cancelled {
                    Button(role: .destructive) { engine.cancelByRecordID(task.id) } label: {
                        Label(t("取消"), systemImage: "xmark")
                    }
                } else {
                    Button { engine.removeFinishedTask(task.id) } label: {
                        Label(t("移除任务"), systemImage: "minus.circle")
                    }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
    }

    private var byteProgress: String {
        let written = ByteCountFormatter.string(fromByteCount: task.downloadedBytes, countStyle: .file)
        guard let total = task.totalBytes, total > 0 else { return written }
        return written + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
