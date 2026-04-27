// swift-tools-version:5.9
// 用法: swift Tests/ConcurrentDownloadBenchmark.swift [URL]
// 测试 GitHub Release CDN 上的并发分片下载 vs 单线程下载的速度差异

import Foundation

// MARK: - 测试配置

/// 测试目标：找一个支持 Range 的大文件
/// 默认使用 GitHub Release asset（通常 30-100MB，CDN 支持 Range）
let testURLString = CommandLine.arguments.dropFirst().first ?? "https://github.com/jipika/WaifuX/releases/download/v1.0.0/WaifuX.dmg"

/// 并发 chunk 数量（与 UpdateChecker 配置一致）
let parallelChunkCount = 6

/// 每个测试重复次数
let repeatCount = 3

/// 超时时间（秒）
let timeoutSeconds: TimeInterval = 300

// MARK: - 颜色输出

struct ANSIColor {
    static let reset = "\u{001B}[0m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let cyan = "\u{001B}[36m"
    static let bold = "\u{001B}[1m"
}

func printHeader(_ text: String) {
    print("\n\(ANSIColor.bold)\(ANSIColor.cyan)═══ \(text) ═══\(ANSIColor.reset)\n")
}

func printResult(label: String, value: String, isGood: Bool? = nil) {
    let color: String
    if let isGood = isGood {
        color = isGood ? ANSIColor.green : ANSIColor.red
    } else {
        color = ANSIColor.yellow
    }
    print("  \(label): \(color)\(value)\(ANSIColor.reset)")
}

// MARK: - 进度追踪器（与 UpdateChecker 一致）

private actor DownloadProgressTracker {
    private var received: Int64 = 0
    private var lastReported: Double = 0
    private let total: Int64
    private let handler: @Sendable (Double) -> Void
    
    init(total: Int64, handler: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.handler = handler
    }
    
    func add(_ bytes: Int64) {
        received += bytes
        let progress = Double(received) / Double(total)
        if progress - lastReported >= 0.01 || received >= total {
            lastReported = progress
            handler(min(progress, 1.0))
        }
    }
}

// MARK: - 单线程下载（与 UpdateChecker.downloadWithProgress 一致）

func downloadSingle(
    session: URLSession,
    request: URLRequest,
    progressHandler: @escaping @Sendable (Double) -> Void
) async throws -> TimeInterval {
    let startTime = Date()
    let (asyncBytes, response) = try await session.bytes(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    
    let expectedLength = response.expectedContentLength
    let tempDir = FileManager.default.temporaryDirectory
    let tempFile = tempDir.appendingPathComponent("single_\(UUID().uuidString).tmp")
    
    FileManager.default.createFile(atPath: tempFile.path, contents: nil)
    let fileHandle = try FileHandle(forWritingTo: tempFile)
    defer { try? fileHandle.close() }
    
    var receivedBytes: Int64 = 0
    var lastReportedProgress: Double = 0
    let bufferSize = 512 * 1024
    var buffer = Data(capacity: bufferSize)
    
    for try await byte in asyncBytes {
        buffer.append(byte)
        receivedBytes += 1
        
        if buffer.count >= bufferSize {
            fileHandle.write(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        
        let currentProgress = Double(receivedBytes) / Double(expectedLength)
        if currentProgress - lastReportedProgress >= 0.01 || receivedBytes >= expectedLength {
            lastReportedProgress = currentProgress
            progressHandler(min(currentProgress, 1.0))
        }
    }
    
    if !buffer.isEmpty {
        fileHandle.write(buffer)
    }
    
    progressHandler(1.0)
    let elapsed = Date().timeIntervalSince(startTime)
    try? FileManager.default.removeItem(at: tempFile)
    return elapsed
}

// MARK: - 多线程分片下载（与 UpdateChecker.downloadParallelWithProgress 一致）

struct ChunkInfo {
    let index: Int
    let file: URL
    let startOffset: Int64
}

func downloadParallel(
    session: URLSession,
    request: URLRequest,
    chunkCount: Int,
    progressHandler: @escaping @Sendable (Double) -> Void
) async throws -> TimeInterval {
    let startTime = Date()
    
    // 1. HEAD 请求
    var headRequest = request
    headRequest.httpMethod = "HEAD"
    let (_, headResponse) = try await session.data(for: headRequest)
    
    guard let httpResponse = headResponse as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    
    let totalSize = headResponse.expectedContentLength
    guard totalSize > 0 else {
        throw URLError(.badServerResponse)
    }
    
    let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges")
    guard acceptRanges?.lowercased() == "bytes" else {
        throw URLError(.unsupportedURL)
    }
    
    // 2. 分片配置（与 UpdateChecker 一致）
    let minChunkSize: Int64 = 1 * 1024 * 1024
    let preferredChunkCount = chunkCount
    let actualChunkCount = max(1, min(preferredChunkCount, Int(totalSize / minChunkSize)))
    let chunkSize = Int(totalSize) / actualChunkCount
    
    let tempDir = FileManager.default.temporaryDirectory
    let finalFile = tempDir.appendingPathComponent("parallel_\(UUID().uuidString).tmp")
    FileManager.default.createFile(atPath: finalFile.path, contents: nil)
    
    let progress = DownloadProgressTracker(total: totalSize, handler: progressHandler)
    
    // 3. 并发下载每个 chunk
    let chunks = try await withThrowingTaskGroup(of: ChunkInfo.self) { group -> [ChunkInfo] in
        for i in 0..<actualChunkCount {
            let start = Int64(i * chunkSize)
            let end = (i == actualChunkCount - 1) ? (totalSize - 1) : (Int64((i + 1) * chunkSize - 1))
            
            group.addTask {
                var chunkRequest = request
                chunkRequest.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                chunkRequest.timeoutInterval = timeoutSeconds
                
                let (asyncBytes, chunkResponse) = try await session.bytes(for: chunkRequest)
                guard let chunkHTTP = chunkResponse as? HTTPURLResponse,
                      (chunkHTTP.statusCode == 200 || chunkHTTP.statusCode == 206) else {
                    throw URLError(.badServerResponse)
                }
                
                let chunkFile = tempDir.appendingPathComponent("chunk_\(i)_\(UUID().uuidString).tmp")
                FileManager.default.createFile(atPath: chunkFile.path, contents: nil)
                let chunkHandle = try FileHandle(forWritingTo: chunkFile)
                defer { try? chunkHandle.close() }
                
                // 与 UpdateChecker 一致的优化：1MB 缓冲 + 1MB 进度批处理
                let writeBufferSize = 1024 * 1024
                let progressBatchSize: Int64 = 1024 * 1024
                
                var buffer = Data(capacity: writeBufferSize)
                var pendingProgress: Int64 = 0
                
                for try await byte in asyncBytes {
                    buffer.append(byte)
                    
                    if buffer.count >= writeBufferSize {
                        chunkHandle.write(buffer)
                        pendingProgress += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        
                        if pendingProgress >= progressBatchSize {
                            await progress.add(pendingProgress)
                            pendingProgress = 0
                        }
                    }
                }
                
                if !buffer.isEmpty {
                    chunkHandle.write(buffer)
                    pendingProgress += Int64(buffer.count)
                }
                
                if pendingProgress > 0 {
                    await progress.add(pendingProgress)
                }
                
                return ChunkInfo(index: i, file: chunkFile, startOffset: start)
            }
        }
        
        var results: [ChunkInfo] = []
        for try await result in group {
            results.append(result)
        }
        return results
    }
    
    // 4. 串行合并
    let finalHandle = try FileHandle(forWritingTo: finalFile)
    defer { try? finalHandle.close() }
    
    for chunk in chunks.sorted(by: { $0.index < $1.index }) {
        let readHandle = try FileHandle(forReadingFrom: chunk.file)
        defer { try? readHandle.close() }
        
        finalHandle.seek(toFileOffset: UInt64(chunk.startOffset))
        
        while true {
            let data = readHandle.readData(ofLength: 512 * 1024)
            if data.isEmpty { break }
            finalHandle.write(data)
        }
        
        try? FileManager.default.removeItem(at: chunk.file)
    }
    
    progressHandler(1.0)
    let elapsed = Date().timeIntervalSince(startTime)
    try? FileManager.default.removeItem(at: finalFile)
    return elapsed
}

// MARK: - 主测试流程

await Task {
    printHeader("WaifuX 更新下载并发基准测试")
    print("测试目标 URL: \(testURLString)")
    print("并发配置: \(parallelChunkCount) 线程")
    print("重复次数: \(repeatCount) 次")
    print("超时时间: \(timeoutSeconds) 秒")
    
    guard let url = URL(string: testURLString) else {
        print("❌ 无效的 URL")
        exit(1)
    }
    
    // 配置 URLSession：与 UpdateChecker 一致，提高并发连接数
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = timeoutSeconds
    config.timeoutIntervalForResource = timeoutSeconds
    config.httpMaximumConnectionsPerHost = 8
    let session = URLSession(configuration: config)
    
    var request = URLRequest(url: url)
    request.setValue("WaifuX-DownloadBenchmark/1.0", forHTTPHeaderField: "User-Agent")
    
    // 先探测文件信息
    print("\n探测文件信息...")
    var headReq = URLRequest(url: url)
    headReq.httpMethod = "HEAD"
    do {
        let (_, response) = try await session.data(for: headReq)
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            let size = response.expectedContentLength
            let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges")
            let speedLimit = http.value(forHTTPHeaderField: "X-RateLimit-Limit")
            print("  文件大小: \(String(format: "%.2f", Double(size) / (1024 * 1024))) MB")
            print("  支持 Range: \(acceptRanges ?? "未知")")
            print("  HTTPMaximumConnectionsPerHost: \(config.httpMaximumConnectionsPerHost)")
            if let speedLimit = speedLimit {
                print("  速率限制: \(speedLimit)")
            }
        } else {
            print("  ⚠️ HEAD 请求返回非 200，继续测试...")
        }
    } catch {
        print("  ⚠️ HEAD 请求失败: \(error.localizedDescription)，继续测试...")
    }
    
    // 单线程基准
    printHeader("单线程下载基准")
    var singleTimes: [TimeInterval] = []
    for i in 1...repeatCount {
        print("  运行 \(i)/\(repeatCount)...", terminator: " ")
        fflush(stdout)
        do {
            let elapsed = try await downloadSingle(session: session, request: request) { p in
                if p >= 1.0 { print("✅ 完成") }
            }
            singleTimes.append(elapsed)
            print("      耗时: \(String(format: "%.2f", elapsed))s")
        } catch {
            print("❌ 失败: \(error)")
        }
    }
    
    guard let singleBest = singleTimes.min() else {
        print("单线程下载全部失败，无法继续测试。")
        session.finishTasksAndInvalidate()
        exit(1)
    }
    
    printResult(label: "单线程最佳耗时", value: "\(String(format: "%.2f", singleBest))s")
    printResult(label: "单线程平均耗时", value: "\(String(format: "%.2f", singleTimes.reduce(0, +) / Double(singleTimes.count)))s")
    
    // 多线程测试
    printHeader("\(parallelChunkCount) 线程并发下载")
    var parallelTimes: [TimeInterval] = []
    for i in 1...repeatCount {
        print("  运行 \(i)/\(repeatCount)...", terminator: " ")
        fflush(stdout)
        do {
            let elapsed = try await downloadParallel(
                session: session,
                request: request,
                chunkCount: parallelChunkCount
            ) { p in
                if p >= 1.0 { print("✅ 完成") }
            }
            parallelTimes.append(elapsed)
            print("      耗时: \(String(format: "%.2f", elapsed))s")
        } catch {
            print("❌ 失败: \(error)")
        }
    }
    
    guard let parallelBest = parallelTimes.min() else {
        print("并发下载全部失败，无法评估。")
        session.finishTasksAndInvalidate()
        exit(1)
    }
    
    printResult(label: "\(parallelChunkCount) 线程最佳耗时", value: "\(String(format: "%.2f", parallelBest))s")
    printResult(label: "\(parallelChunkCount) 线程平均耗时", value: "\(String(format: "%.2f", parallelTimes.reduce(0, +) / Double(parallelTimes.count)))s")
    
    // 汇总报告
    printHeader("📊 汇总报告")
    let speedup = singleBest / parallelBest
    let avgSpeedup = (singleTimes.reduce(0, +) / Double(singleTimes.count)) / (parallelTimes.reduce(0, +) / Double(parallelTimes.count))
    
    printResult(label: "单线程基准（最佳）", value: "\(String(format: "%.2f", singleBest))s")
    printResult(label: "\(parallelChunkCount) 线程（最佳）", value: "\(String(format: "%.2f", parallelBest))s")
    printResult(label: "最佳加速比", value: "\(String(format: "%.2f", speedup))x", isGood: speedup > 1.2)
    printResult(label: "平均加速比", value: "\(String(format: "%.2f", avgSpeedup))x", isGood: avgSpeedup > 1.2)
    
    // 用单线程最佳耗时算带宽
    if let headResponse = try? await session.data(for: headReq).1,
       let http = headResponse as? HTTPURLResponse, http.statusCode == 200 {
        let totalSize = headResponse.expectedContentLength
        let singleBandwidth = Double(totalSize) / singleBest / (1024 * 1024)
        let parallelBandwidth = Double(totalSize) / parallelBest / (1024 * 1024)
        printResult(label: "单线程带宽", value: "\(String(format: "%.2f", singleBandwidth)) MB/s")
        printResult(label: "\(parallelChunkCount) 线程带宽", value: "\(String(format: "%.2f", parallelBandwidth)) MB/s")
    }
    
    if speedup < 1.2 {
        print("\n  \(ANSIColor.yellow)⚠️ 警告: 并发下载未明显提速，可能原因:\(ANSIColor.reset)")
        print("     1. 服务器 CDN 对同一 IP 的并发连接做了限速（常见于 GitHub/S3）")
        print("     2. 本地带宽已接近上限，多线程无法突破物理带宽")
        print("     3. 网络延迟很低，TCP 慢启动的收益有限")
        print("     4. 可以尝试更高的 httpMaximumConnectionsPerHost（当前 \(config.httpMaximumConnectionsPerHost)）")
    } else {
        print("\n  \(ANSIColor.green)✅ 并发下载有效，建议保持 \(parallelChunkCount) 线程配置\(ANSIColor.reset)")
    }
    
    session.finishTasksAndInvalidate()
    exit(0)
}.value
