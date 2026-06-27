import AVFoundation
import Foundation

/// B 帧视频自动转码服务
///
/// 有 B 帧 + 高码率的视频 seek 时需要逐帧解码导致卡顿。
/// 使用 AVAssetWriter 转码为无 B 帧格式，seek 直接跳到最近 I 帧。
/// 转码结果直接覆盖原文件。
enum VideoTranscodeService {

    /// 码率阈值：低于此值即使有 B 帧也不会卡
    private static let bitrateThreshold: Double = 8_000_000

    // MARK: - Public

    /// 检查视频是否需要转码（有 B 帧且高码率），需要则转码并覆盖原文件。
    static func ensureSeekFriendly(_ videoURL: URL, progress: (@Sendable (Double) -> Void)? = nil) async -> URL {
        guard videoURL.isFileURL else { return videoURL }

        let info = analyze(videoURL)
        guard info.needsTranscode else { return videoURL }

        let tmpURL = videoURL.appendingPathExtension("transcoding.mp4")
        let videoURLCopy = videoURL
        let success: Bool = await Task.detached(priority: .userInitiated) {
            transcode(videoURLCopy, info: info, outputURL: tmpURL, progress: progress)
        }.value

        guard success else { return videoURL }

        do {
            try FileManager.default.removeItem(at: videoURL)
            try FileManager.default.moveItem(at: tmpURL, to: videoURL)
            return videoURL
        } catch {
            print("[VideoTranscodeService] Replace failed: \(error)")
            try? FileManager.default.removeItem(at: tmpURL)
            return videoURL
        }
    }

    // MARK: - 分析

    struct VideoInfo {
        let width: Int
        let height: Int
        let bitrate: Double
        let fps: Double
        let hasBFrames: Bool
        let needsTranscode: Bool
    }

    static func analyze(_ url: URL) -> VideoInfo {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return VideoInfo(width: 0, height: 0, bitrate: 0, fps: 0, hasBFrames: false, needsTranscode: false)
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        let w = Int(abs(size.width)), h = Int(abs(size.height))
        let br = Double(track.estimatedDataRate)
        let fps = Double(track.nominalFrameRate)
        let bframes = track.requiresFrameReordering
        return VideoInfo(width: w, height: h, bitrate: br, fps: fps, hasBFrames: bframes,
                         needsTranscode: bframes && br > bitrateThreshold)
    }

    // MARK: - AVAssetWriter 转码

    private static func transcode(_ inputURL: URL, info: VideoInfo, outputURL: URL, progress: ((Double) -> Void)?) -> Bool {
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVAsset(url: inputURL)
        let duration = asset.duration.seconds

        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        guard let writer = try? AVAssetWriter(url: outputURL, fileType: .mp4) else { return false }
        writer.shouldOptimizeForNetworkUse = true

        // --- Video track ---
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return false }

        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        reader.add(videoOutput)

        let videoInputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: info.width,
            AVVideoHeightKey: info.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(max(info.bitrate * 1.1, info.bitrate + 500_000)),
                AVVideoMaxKeyFrameIntervalKey: Int(info.fps),
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoInputSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // --- Audio track ---
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(aOut)
            audioOutput = aOut

            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            aIn.expectsMediaDataInRealTime = false
            writer.add(aIn)
            audioInput = aIn
        }

        guard reader.startReading(), writer.startWriting() else {
            print("[VideoTranscodeService] Start failed: \(reader.error ?? writer.error)")
            return false
        }
        writer.startSession(atSourceTime: .zero)

        // 等待视频 + 音频都完成
        let group = DispatchGroup()

        // 视频
        group.enter()
        let videoQueue = DispatchQueue(label: "transcode.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                guard let buf = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                if !videoInput.append(buf) { videoInput.markAsFinished(); group.leave(); return }
                let pts = CMSampleBufferGetPresentationTimeStamp(buf).seconds
                if duration > 0, pts.isFinite { progress?(min(pts / duration, 1.0)) }
            }
        }

        // 音频
        if let audioOutput, let audioInput {
            group.enter()
            let audioQueue = DispatchQueue(label: "transcode.audio")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let buf = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    if !audioInput.append(buf) { audioInput.markAsFinished(); group.leave(); return }
                }
            }
        }

        // 等待全部完成
        group.wait()

        let finishSem = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSem.signal() }
        finishSem.wait()

        if writer.status == .failed {
            print("[VideoTranscodeService] Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }

        return writer.status == .completed
    }
}
