import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - VideoToolbox 视频处理服务

/// 使用 VideoToolbox 进行视频硬件加速处理
/// 支持视频解码、帧提取、超分辨率等功能
actor VideoToolboxProcessor {
    static let shared = VideoToolboxProcessor()

    private var decompressionSession: VTDecompressionSession?

    // MARK: - 视频信息

    struct VideoInfo {
        let width: Int
        let height: Int
        let frameRate: Float
        let codecType: CMVideoCodecType
        let duration: CMTime
    }

    // MARK: - 创建视频信息

    /// 从 URL 获取视频信息
    func getVideoInfo(url: URL) async throws -> VideoInfo {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoToolboxError.noVideoTrack
        }

        let size = try await track.load(.naturalSize)
        let frameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let formatDescriptions = try await track.load(.formatDescriptions)

        guard let formatDescription = formatDescriptions.first else {
            throw VideoToolboxError.invalidFormat
        }

        let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)

        return VideoInfo(
            width: Int(size.width),
            height: Int(size.height),
            frameRate: frameRate,
            codecType: codecType,
            duration: duration
        )
    }

    // MARK: - 帧提取

    /// 从视频中提取指定时间的帧
    func extractFrame(from url: URL, at time: CMTime) async throws -> CGImage {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let image = image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: VideoToolboxError.frameExtractionFailed)
                }
            }
        }

        return cgImage
    }

    // MARK: - 缩放视频帧

    /// 使用 VideoToolbox 缩放视频帧到目标尺寸
    func scaleFrame(_ pixelBuffer: CVPixelBuffer, to size: CGSize) throws -> CVPixelBuffer {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)

        // 如果尺寸相同，直接返回原帧
        if sourceWidth == Int(size.width) && sourceHeight == Int(size.height) {
            return pixelBuffer
        }

        var destinationBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &destinationBuffer
        )

        guard status == kCVReturnSuccess, let destination = destinationBuffer else {
            throw VideoToolboxError.bufferCreationFailed
        }

        // 使用 Core Video 进行缩放
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(destination),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(destination),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let cgContext = context else {
            throw VideoToolboxError.contextCreationFailed
        }

        let sourceColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let sourceData = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VideoToolboxError.invalidPixelBuffer
        }

        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sourceProvider = CGDataProvider(
            dataInfo: nil,
            data: sourceData,
            size: sourceBytesPerRow * sourceHeight
        ) { _, _, _ in }

        guard let sourceProvider = sourceProvider else {
            throw VideoToolboxError.dataProviderCreationFailed
        }

        guard let sourceImage = CGImage(
            width: sourceWidth,
            height: sourceHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: sourceBytesPerRow,
            space: sourceColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: sourceProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw VideoToolboxError.imageCreationFailed
        }

        cgContext.interpolationQuality = .high
        cgContext.draw(sourceImage, in: CGRect(origin: .zero, size: size))

        return destination
    }

    // MARK: - 硬件加速解码

    /// 创建硬件加速解码会话
    func createDecompressionSession(formatDescription: CMFormatDescription) throws {
        let destinationAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord()

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &decompressionSession
        )

        guard status == noErr, decompressionSession != nil else {
            throw VideoToolboxError.sessionCreationFailed
        }
    }

    /// 释放解码会话
    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
    }

    deinit {
        Task { await invalidate() }
    }
}

// MARK: - 错误类型

enum VideoToolboxError: Error, LocalizedError {
    case noVideoTrack
    case invalidFormat
    case frameExtractionFailed
    case bufferCreationFailed
    case contextCreationFailed
    case invalidPixelBuffer
    case dataProviderCreationFailed
    case imageCreationFailed
    case sessionCreationFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "视频中没有找到视频轨道"
        case .invalidFormat:
            return "无效的视频格式"
        case .frameExtractionFailed:
            return "帧提取失败"
        case .bufferCreationFailed:
            return "像素缓冲区创建失败"
        case .contextCreationFailed:
            return "图形上下文创建失败"
        case .invalidPixelBuffer:
            return "无效的像素缓冲区"
        case .dataProviderCreationFailed:
            return "数据提供者创建失败"
        case .imageCreationFailed:
            return "图像创建失败"
        case .sessionCreationFailed:
            return "解码会话创建失败"
        case .decodingFailed:
            return "视频解码失败"
        }
    }
}

// MARK: - CVPixelBuffer 扩展

extension CVPixelBuffer {
    /// 将 CVPixelBuffer 转换为 CGImage
    func toCGImage() -> CGImage? {
        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(self),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(self),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }
}
