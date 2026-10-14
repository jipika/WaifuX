//  IOSurface 帧渲染器
//
//  替代 AVAssetReader 文件解码路径，通过 IOSurface 接收主 App 解码后的视频帧。
//  App 写入 IOSurface → 扩展通过 IOSurfaceLookup 读取 → CMSampleBuffer → AVSampleBufferDisplayLayer。
//
//  使用 AVSampleBufferVideoRenderer.requestMediaDataWhenReady 驱动帧消费，
//  与 Phosphene 的 VideoRenderer 使用相同的渲染管道模式。
//
//  每显示器使用 2 个 IOSurface 实现双缓冲（避免写时读的撕裂）。
//  surfaceIndex 在 0 和 1 之间交替，App 写入 idle 面，扩展读取 active 面。

import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface
import os

final class IOSurfaceFrameRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    let displayID: UInt32

    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "io-surface-renderer", qos: .userInitiated)
    private var isRunning = true
    private(set) var isPaused = false
    private var isRequestingMediaData = false
    private var hasLoggedFirstFrame = false
    private var hasLoggedFirstEnqueue = false
    /// 外部可读取：是否已收到至少一帧（用于 acquire 超时检测）
    var hasReceivedFirstFrame: Bool { hasLoggedFirstEnqueue }
    private var hasLoggedForeignSurface = false
    private var lastPresentedSurface: IOSurface?

    // 双缓冲 IOSurface
    var surfaces: [IOSurface?] = [nil, nil]
    private var activeIndex = 0

    // 帧计时
    private var lastFramePTS: CMTime = .zero
    private var frameDuration: CMTime = CMTime(value: 1, timescale: 60)
    private var hasSetInitialTimebase = false

    // 保留每 surface 的 CVPixelBuffer，防止 CMSampleBuffer 不 retain image buffer 导致提前释放
    private var surfacePixelBuffers: [IOSurfaceID: CVPixelBuffer] = [:]

    // 待处理帧（生产者-消费者模式）
    fileprivate struct PendingFrame {
        let surfaceID: IOSurfaceID
        let timestamp: CMTime
        let duration: CMTime
    }
    private var pendingFrame: PendingFrame?
    private let pendingLock = OSAllocatedUnfairLock(initialState: Optional<PendingFrame>.none)

    /// 创建帧渲染器并预分配 IOSurface
    static func create(displayID: UInt32, rootLayer: CALayer, width: Int, height: Int) -> IOSurfaceFrameRenderer {
        let displayLayer = AVSampleBufferDisplayLayer()
        // 正常帧已匹配显示尺寸；旋转/重分配期间的旧帧也不能被非等比挤压。
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        displayLayer.isHidden = true
        rootLayer.addSublayer(displayLayer)

        let renderer = IOSurfaceFrameRenderer(displayID: displayID, displayLayer: displayLayer)
        renderer.allocateSurfaces(width: width, height: height)
        return renderer
    }

    private init(displayID: UInt32, displayLayer: AVSampleBufferDisplayLayer) {
        self.displayID = displayID
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase
    }

    /// 预分配双缓冲 IOSurface
    private func allocateSurfaces(width: Int, height: Int) {
        let bytesPerRow = (width * 4 + 15) & ~15 // 16 字节对齐
        let allocSize = bytesPerRow * height

        for i in 0..<2 {
            var props: [IOSurfacePropertyKey: Any] = [
                .width: width,
                .height: height,
                .bytesPerElement: 4,
                .bytesPerRow: bytesPerRow,
                .allocSize: allocSize,
                .pixelFormat: 0x4247_5241, // 'BGRA'
            ]
            props[IOSurfacePropertyKey(rawValue: "IOSurfaceIsGlobal")] = true
            surfaces[i] = IOSurface(properties: props)
            if #available(macOS 15.0, *), let surfaceID = surfaces[i]?.surfaceID {
                extLog("[IOSurfaceRenderer] surface[\(i)] id=\(surfaceID) global=true")
            }
        }
        extLog("[IOSurfaceRenderer] 已分配 \(width)x\(height) 双缓冲")
    }

    /// 返回当前可用于 App 写入的空闲 IOSurface ID
    var idleSurfaceID: IOSurfaceID? {
        guard #available(macOS 15.0, *) else { return nil }
        let idleIndex = 1 - activeIndex
        return surfaces[idleIndex]?.surfaceID
    }

    /// 显示器几何变化时重新布局。调用方在主线程上执行。
    func relayout(rootLayer: CALayer) {
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        extLog("[IOSurfaceRenderer] relayout display=\(displayID) bounds=\(Int(rootLayer.bounds.width))x\(Int(rootLayer.bounds.height)) scale=\(rootLayer.contentsScale)")
    }

    /// 显示器分辨率变化时重新分配 surface 并返回新 ID。
    /// 调用方在主线程上调用，完成后通过 socket 重新注册 surface。
    @available(macOS 15.0, *)
    func reallocateSurfacesIfNeeded(width: Int, height: Int) -> (surfaceID0: IOSurfaceID, surfaceID1: IOSurfaceID)? {
        let currentWidth = surfaces[0]?.width ?? 0
        let currentHeight = surfaces[0]?.height ?? 0
        guard currentWidth != width || currentHeight != height else { return nil }

        extLog("[IOSurfaceRenderer] reallocating surfaces display=\(displayID) \(currentWidth)x\(currentHeight) -> \(width)x\(height)")
        allocateSurfaces(width: width, height: height)
        guard let s0 = surfaces[0]?.surfaceID, let s1 = surfaces[1]?.surfaceID else { return nil }
        return (s0, s1)
    }

    /// App 通知新帧已写入指定 surface（由 FrameChannel 回调调用）。
    /// 此处只存储帧元数据，实际的 CMSampleBuffer 创建和 enqueue 由
    /// requestMediaDataWhenReady 的回调执行。
    func frameReady(surfaceID: IOSurfaceID, timestamp: CMTime, duration: CMTime?) {
        guard #available(macOS 15.0, *), isRunning else { return }
        let dur = duration ?? frameDuration
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingLock.withLock { $0 = PendingFrame(surfaceID: surfaceID, timestamp: timestamp, duration: dur) }
            if !self.hasLoggedFirstFrame {
                self.hasLoggedFirstFrame = true
                extLog("[IOSurfaceRenderer] 收到首帧 display=\(self.displayID) surface=\(surfaceID)")
            }
            self.startRequestingMediaDataIfNeeded()
        }
    }

    /// 从指定 surface 创建 CMSampleBuffer 并 enqueue
    @available(macOS 15.0, *)
    private func enqueueSurface(surfaceID: IOSurfaceID, timestamp: CMTime, duration: CMTime) {
        let surface: IOSurface
        if let idx = surfaces.firstIndex(where: { $0?.surfaceID == surfaceID }),
           let knownSurface = surfaces[idx] {
            activeIndex = idx
            surface = knownSurface
        } else {
            guard let ref = IOSurfaceLookup(surfaceID) else {
                extLog("[IOSurfaceRenderer] ⚠️ 无法查找 surfaceID: \(surfaceID)")
                return
            }
            surface = unsafeBitCast(ref, to: IOSurface.self)
            if !hasLoggedForeignSurface {
                hasLoggedForeignSurface = true
                extLog("[IOSurfaceRenderer] ⚠️ 使用外部 surfaceID: \(surfaceID)")
            }
        }

        if duration.isValid, duration > .zero { frameDuration = duration }
        lastPresentedSurface = surface

        // IOSurface → CVPixelBuffer
        var unmanagedBuf: Unmanaged<CVPixelBuffer>?
        let cvStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            nil,
            &unmanagedBuf
        )

        guard cvStatus == kCVReturnSuccess, let unmanagedBuf else {
            extLog("[IOSurfaceRenderer] ❌ CVPixelBufferCreateWithIOSurface 失败: \(cvStatus)")
            return
        }
        // 使用 takeRetainedValue 将引用计数交给 ARC；随后存入 surfacePixelBuffers 保持存活，
        // 避免 CMSampleBufferCreateReadyWithImageBuffer 不保留 image buffer 导致提前释放。
        let pixelBuffer = unmanagedBuf.takeRetainedValue()

        // CVPixelBuffer → CMSampleBuffer
        var formatDesc: CMVideoFormatDescription?
        let fmStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard fmStatus == noErr, let formatDesc else {
            extLog("[IOSurfaceRenderer] ❌ CMVideoFormatDescriptionCreate 失败: \(fmStatus)")
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: timestamp,
            decodeTimeStamp: timestamp
        )

        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer else {
            extLog("[IOSurfaceRenderer] ❌ CMSampleBufferCreateReadyWithImageBuffer 失败")
            return
        }

        lastFramePTS = timestamp

        // 首帧到达时同步 timebase，防止 App 晚于扩展启动导致帧被当迟到丢弃
        if !hasSetInitialTimebase {
            hasSetInitialTimebase = true
            CMTimebaseSetRate(timebase, rate: 0.0)
            CMTimebaseSetTime(timebase, time: timestamp)
            CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
        }

        renderer.enqueue(sampleBuffer)
        if !hasLoggedFirstEnqueue {
            hasLoggedFirstEnqueue = true
            // 首帧到达时清理静态 fallback，让 IOSurface 动态层接管显示。
            if let parent = displayLayer.superlayer {
                parent.contents = nil
                for sub in parent.sublayers ?? [] {
                    if sub !== displayLayer, sub is AVSampleBufferDisplayLayer {
                        sub.removeFromSuperlayer()
                    }
                }
            }
            if displayLayer.isHidden {
                displayLayer.isHidden = false
            }
            extLog("[IOSurfaceRenderer] 🔄 首帧到达，已清理静态底图并恢复 IOSurface 层 display=\(displayID)")
            extLog("[IOSurfaceRenderer] 首帧已入队 display=\(displayID) pts=\(timestamp.seconds)")
        }

        // 将 pixel buffer 存入字典保持引用，直到同一 surface 的下一帧覆盖或 stop 清空。
        // CMSampleBufferCreateReadyWithImageBuffer 不会保留 image buffer。
        surfacePixelBuffers[surfaceID] = pixelBuffer
    }

    @available(macOS 15.0, *)
    func start() {
        CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
    }

    func stop() {
        queue.sync {
            isRunning = false
            renderer.stopRequestingMediaData()
            isRequestingMediaData = false
            hasSetInitialTimebase = false
            hasLoggedFirstFrame = false
            hasLoggedFirstEnqueue = false
            surfacePixelBuffers.removeAll()
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        CMTimebaseSetRate(timebase, rate: 1.0)
    }

    @available(macOS 15.0, *)
    private func startRequestingMediaDataIfNeeded() {
        guard !isRequestingMediaData else { return }
        isRequestingMediaData = true

        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            guard self.isRunning else {
                self.renderer.stopRequestingMediaData()
                self.isRequestingMediaData = false
                return
            }

            while self.renderer.isReadyForMoreMediaData {
                guard let frame = self.pendingLock.withLock({ $0.take() }) else {
                    self.renderer.stopRequestingMediaData()
                    self.isRequestingMediaData = false
                    return
                }
                self.enqueueSurface(surfaceID: frame.surfaceID, timestamp: frame.timestamp, duration: frame.duration)
            }
        }
    }

    func makeSnapshotXPC() -> AnyObject? {
        queue.sync {
            guard let surface = lastPresentedSurface ?? surfaces[activeIndex] else { return nil }
            return createSnapshotXPC(from: surface)
        }
    }

    private func createSnapshotXPC(from surface: IOSurface) -> AnyObject? {
        guard let snapshotClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
              let instance = class_createInstance(snapshotClass, 0) else {
            extLog("  [Snapshot] Failed to create WallpaperSnapshotXPC from IOSurface")
            return nil
        }

        let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
        let instancePtr = Unmanaged.passUnretained(instance as AnyObject).toOpaque()
        instancePtr.advanced(by: 8).storeBytes(of: surfaceRef, as: UnsafeMutableRawPointer.self)
        return instance as AnyObject
    }
}

// MARK: - Optional 扩展（用于 take 语义）

extension Optional where Wrapped == IOSurfaceFrameRenderer.PendingFrame {
    /// 取出值并设置为 nil，返回被取出的值
    fileprivate mutating func take() -> Wrapped? {
        let val = self
        self = nil
        return val
    }
}
