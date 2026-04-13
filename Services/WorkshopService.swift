import Foundation

// MARK: - Workshop Service
///
/// 处理 Wallpaper Engine Steam 创意工坊的搜索和下载
@MainActor
class WorkshopService: ObservableObject {
    static let shared = WorkshopService()
    
    // MARK: - Published State
    
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchResults: [WorkshopWallpaper] = []
    @Published var hasMorePages = false
    
    // MARK: - Configuration
    
    private let wallpaperEngineAppID = "431960"
    private let steamAPIBase = "https://api.steampowered.com"
    private var currentPage = 1
    private let pageSize = 20
    
    // MARK: - Search
    
    func search(params: WorkshopSearchParams) async throws -> WorkshopSearchResponse {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            currentPage = params.page
        }
        
        defer {
            Task { @MainActor in
                isLoading = false
            }
        }
        
        var components = URLComponents(string: "\(steamAPIBase)/IPublishedFileService/QueryFiles/v1/")
        
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "appid", value: wallpaperEngineAppID),
            URLQueryItem(name: "page", value: String(params.page)),
            URLQueryItem(name: "numperpage", value: String(params.pageSize)),
            URLQueryItem(name: "return_metadata", value: "1"),
            URLQueryItem(name: "return_details", value: "1")
        ]
        
        if !params.query.isEmpty {
            queryItems.append(URLQueryItem(name: "search_text", value: params.query))
        }
        
        components?.queryItems = queryItems
        
        guard let url = components?.url else {
            throw WorkshopError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WorkshopError.apiError("Steam API request failed")
        }
        
        let steamResponse = try JSONDecoder().decode(SteamPublishedFileResponse.self, from: data)
        
        let items = steamResponse.response.publishedfiledetails?.compactMap { detail -> WorkshopWallpaper? in
            WorkshopWallpaper(from: detail)
        } ?? []
        
        let total = steamResponse.response.total
        let hasMore = (params.page * params.pageSize) < total
        
        await MainActor.run {
            if params.page == 1 {
                searchResults = items
            } else {
                searchResults.append(contentsOf: items)
            }
            hasMorePages = hasMore
        }
        
        return WorkshopSearchResponse(
            items: items,
            total: total,
            page: params.page,
            hasMore: hasMore
        )
    }
    
    func loadMore(currentParams: WorkshopSearchParams) async throws -> WorkshopSearchResponse {
        var params = currentParams
        params.page = currentPage + 1
        return try await search(params: params)
    }
    
    // MARK: - SteamCMD
    
    func downloadWorkshopItem(workshopID: String, useAnonymous: Bool = true) async throws -> URL {
        guard let steamcmdPath = Bundle.main.url(forResource: "steamcmd", withExtension: nil, subdirectory: "steamcmd") else {
            throw WorkshopError.steamcmdNotFound
        }
        
        let downloadDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WaifuX/Workshop/\(workshopID)")
        
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        
        var arguments: [String] = [
            "+@sSteamCmdForcePlatformType", "windows",
            "+force_install_dir", downloadDir.path
        ]
        
        if useAnonymous {
            arguments += ["+login", "anonymous"]
        } else if let credentials = WorkshopSourceManager.shared.steamCredentials {
            arguments += ["+login", credentials.username, credentials.password]
        } else {
            throw WorkshopError.credentialsRequired
        }
        
        arguments += [
            "+workshop_download_item", wallpaperEngineAppID, workshopID,
            "+quit"
        ]
        
        let task = Process()
        task.executableURL = steamcmdPath
        task.arguments = arguments
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        return try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { _ in
                if task.terminationStatus == 0 {
                    let contentPath = downloadDir
                        .appendingPathComponent("steamapps/workshop/content/\(self.wallpaperEngineAppID)/\(workshopID)")
                    
                    if FileManager.default.fileExists(atPath: contentPath.path) {
                        continuation.resume(returning: contentPath)
                    } else {
                        continuation.resume(throwing: WorkshopError.downloadIncomplete)
                    }
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: WorkshopError.downloadFailed(errorString))
                }
            }
            
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: WorkshopError.executionFailed(error.localizedDescription))
            }
        }
    }
    
    func checkSteamCMDStatus() -> SteamCMDStatus {
        guard let steamcmdPath = Bundle.main.url(forResource: "steamcmd", withExtension: nil, subdirectory: "steamcmd") else {
            return .notInstalled
        }
        
        guard FileManager.default.fileExists(atPath: steamcmdPath.path) else {
            return .notInstalled
        }
        
        return .ready
    }
}

// MARK: - Error & Status

enum WorkshopError: LocalizedError {
    case invalidURL
    case apiError(String)
    case steamcmdNotFound
    case credentialsRequired
    case downloadIncomplete
    case downloadFailed(String)
    case executionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .apiError(let msg): return "API Error: \(msg)"
        case .steamcmdNotFound: return "SteamCMD not found"
        case .credentialsRequired: return "Steam credentials required"
        case .downloadIncomplete: return "Download incomplete"
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .executionFailed(let msg): return "Execution failed: \(msg)"
        }
    }
}

enum SteamCMDStatus {
    case notInstalled
    case ready
    case downloading
    case error(String)
}
