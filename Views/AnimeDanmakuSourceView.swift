import SwiftUI

/// Manual correction for title matches: search an anime, then select its exact episode.
@MainActor
struct AnimeDanmakuSourceView: View {
    let animeTitle: String
    let onSelect: (DanmakuEpisode) -> Void

    @Environment(\.dismiss) private var dismiss
    // The editable search text is intentionally seeded once from the presented anime.
    @State private var query: String
    @State private var results: [DanmakuAnime] = []
    @State private var selectedAnimeID: Int?
    @State private var isLoading = false
    @State private var didSearch = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration: UUID?

    init(animeTitle: String, onSelect: @escaping (DanmakuEpisode) -> Void) {
        self.animeTitle = animeTitle
        self.onSelect = onSelect
        _query = State(initialValue: animeTitle)
    }

    private var selectedEpisodes: [DanmakuEpisode] {
        var seen = Set<Int>()
        return (selectedAnime?.episodes ?? []).filter { seen.insert($0.episodeId).inserted }
    }

    private var selectedAnime: DanmakuAnime? {
        results.first { $0.animeId == selectedAnimeID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("danmaku.source.title")).font(.headline)
                Spacer()
                Button(t("danmaku.source.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                TextField(t("danmaku.source.searchPlaceholder"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button(t("danmaku.source.search")) { search() }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(t("danmaku.source.loading")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.bubble").font(.largeTitle).foregroundStyle(.secondary)
                    Text(errorMessage).multilineTextAlignment(.center)
                    Button(t("danmaku.source.retry")) { search() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.secondary)
                    Text(t(didSearch ? "danmaku.source.empty" : "danmaku.source.hint"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sourceLists
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 500)
        .onAppear { search() }
        .onChange(of: query) { _, _ in
            // Edits invalidate an in-flight response; only explicit submit starts a new search.
            searchGeneration = nil
            searchTask?.cancel()
            isLoading = false
        }
        .onDisappear {
            searchGeneration = nil
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private var sourceLists: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(results) { anime in
                        Button {
                            selectAnime(anime)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(anime.animeTitle).font(.body).multilineTextAlignment(.leading)
                                Text(anime.typeDescription).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(selectedAnimeID == anime.animeId ? Color.accentColor.opacity(0.15) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedAnimeID == anime.animeId ? .isSelected : [])
                    }
                }
                .padding(.trailing, 12)
            }
            .frame(width: 270)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(t("danmaku.source.chooseEpisode")).font(.subheadline).foregroundStyle(.secondary)
                if let anime = selectedAnime, !anime.episodes.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(selectedEpisodes) { episode in
                                Button {
                                    onSelect(episode)
                                    dismiss()
                                } label: {
                                    HStack(alignment: .top) {
                                        Text(episode.episodeNumber).monospacedDigit().foregroundStyle(.secondary)
                                            .frame(minWidth: 32, alignment: .leading)
                                        Text(episode.episodeTitle).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Text(t("danmaku.source.noEpisodes"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.leading, 16)
        }
    }

    private func selectAnime(_ anime: DanmakuAnime) {
        selectedAnimeID = anime.animeId
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        isLoading = true
        errorMessage = nil
        searchTask = Task { @MainActor in
            do {
                let detail = try await DanmakuService.shared.getAnime(animeID: anime.animeId)
                try Task.checkCancellation()
                guard searchGeneration == generation, selectedAnimeID == anime.animeId else { return }
                if let detail, let index = results.firstIndex(where: { $0.animeId == anime.animeId }) {
                    results[index] = DanmakuAnime(animeId: anime.animeId,
                        animeTitle: detail.animeTitle.isEmpty ? anime.animeTitle : detail.animeTitle,
                        type: detail.type.isEmpty ? anime.type : detail.type,
                        typeDescription: detail.typeDescription.isEmpty ? anime.typeDescription : detail.typeDescription,
                        episodes: detail.episodes)
                }
                isLoading = false
            } catch {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                errorMessage = t("danmaku.source.networkError")
                isLoading = false
            }
        }
    }

    private func search() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        isLoading = true
        errorMessage = nil
        didSearch = true
        results = []
        selectedAnimeID = nil
        searchTask = Task { @MainActor in
            do {
                let animes = try await DanmakuService.shared.searchAnime(keyword: keyword)
                try Task.checkCancellation()
                guard searchGeneration == generation else { return }
                var seenIDs = Set<Int>()
                results = animes.filter { seenIDs.insert($0.animeId).inserted }
                isLoading = false
                if let first = results.first { selectAnime(first) }
            } catch {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                errorMessage = t("danmaku.source.networkError")
                isLoading = false
            }
        }
    }
}
