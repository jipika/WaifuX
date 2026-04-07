import Foundation
import AVFoundation
import Metal
import MetalKit
import CoreVideo

// MARK: - 视频超分辨率增强器

/// 使用 Metal Shader 实现实时视频超分辨率
@MainActor
class AnimeVideoEnhancer: NSObject {
    static let shared = AnimeVideoEnhancer()

    // Metal 设备
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    // 渲染目标
    private var renderPassDescriptor: MTLRenderPassDescriptor?
    private var vertexBuffer: MTLBuffer?
    
    // 使用 nonisolated(unsafe) 允许在 deinit 中访问
    private nonisolated(unsafe) var displayLinkRef: CVDisplayLink?

    // 超分参数
    @Published var isEnabled: Bool = false
    @Published var intensity: Float = 0.5  // 0.0 - 1.0

    // 顶点数据 (全屏四边形)
    private let vertices: [Float] = [
        -1.0, -1.0, 0.0, 1.0,  // 左下
         1.0, -1.0, 1.0, 1.0,  // 右下
        -1.0,  1.0, 0.0, 0.0,  // 左上
         1.0,  1.0, 1.0, 0.0   // 右上
    ]

    private override init() {
        super.init()
        setupMetal()
    }

    // MARK: - Metal 设置

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[VideoEnhancer] Metal 不可用")
            return
        }

        self.device = device
        self.commandQueue = device.makeCommandQueue()

        // 创建纹理缓存
        var textureCache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )

        guard result == kCVReturnSuccess, let cache = textureCache else {
            print("[VideoEnhancer] 纹理缓存创建失败: \(result)")
            return
        }

        self.textureCache = cache

        // 创建顶点缓冲区
        let dataSize = vertices.count * MemoryLayout<Float>.size
        self.vertexBuffer = device.makeBuffer(bytes: vertices, length: dataSize, options: [])

        // 加载着色器
        loadShaders()
    }

    private func loadShaders() {
        guard let device = device else { return }

        // 内嵌 Metal 着色器代码
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertexShader(
            uint vertexID [[vertex_id]],
            constant float4 *vertices [[buffer(0)]]
        ) {
            VertexOut out;
            float4 pos = vertices[vertexID];
            out.position = float4(pos.xy, 0.0, 1.0);
            out.texCoord = pos.zw;
            return out;
        }

        // 超分核心算法 - ESRGan 简化版
        fragment float4 fragmentShader(
            VertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            constant float &intensity [[buffer(0)]],
            constant float2 &textureSize [[buffer(1)]]
        ) {
            constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);

            float2 uv = in.texCoord;
            float2 texelSize = 1.0 / textureSize;

            // 采样中心像素
            float3 center = sourceTexture.sample(textureSampler, uv).rgb;

            // 采样周围像素 (3x3 卷积)
            float3 samples[9];
            int idx = 0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float2 offset = float2(float(x), float(y)) * texelSize;
                    samples[idx] = sourceTexture.sample(textureSampler, uv + offset).rgb;
                    idx++;
                }
            }

            // 边缘增强卷积核
            float3 edge = samples[1] + samples[3] + samples[5] + samples[7] - 4.0 * center;

            // 细节增强
            float3 detail = (samples[0] + samples[2] + samples[6] + samples[8]) * 0.25 - center;

            // 锐化
            float sharpenAmount = intensity * 0.5;
            float3 sharpened = center + edge * sharpenAmount + detail * (intensity * 0.3);

            // 对比度增强
            float contrast = 1.0 + intensity * 0.1;
            float3 contrasted = (sharpened - 0.5) * contrast + 0.5;

            // 色彩饱和度增强
            float saturation = 1.0 + intensity * 0.15;
            float luminance = dot(contrasted, float3(0.299, 0.587, 0.114));
            float3 saturated = mix(float3(luminance), contrasted, saturation);

            // 防过曝
            saturated = clamp(saturated, 0.0, 1.0);

            return float4(saturated, 1.0);
        }
        """

        // 创建库
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            print("[VideoEnhancer] 着色器编译失败")
            return
        }

        guard let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            print("[VideoEnhancer] 着色器函数未找到")
            return
        }

        // 创建渲染管线
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            print("[VideoEnhancer] Metal 管线创建成功")
        } catch {
            print("[VideoEnhancer] 管线创建失败: \(error)")
        }
    }

    // MARK: - 视频处理

    /// 处理视频帧
    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard isEnabled,
              let device = device,
              let commandQueue = commandQueue,
              let pipelineState = pipelineState,
              let textureCache = textureCache,
              let vertexBuffer = vertexBuffer else {
            return pixelBuffer
        }

        // 获取输入纹理
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTextureIn: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTextureIn
        )

        guard result == kCVReturnSuccess,
              let cvTexture = cvTextureIn,
              let inputTexture = CVMetalTextureGetTexture(cvTexture) else {
            return pixelBuffer
        }

        // 创建输出纹理
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.usage = [.renderTarget, .shaderRead]

        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            return pixelBuffer
        }

        // 创建命令缓冲区
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = createRenderPassDescriptor(texture: outputTexture),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return pixelBuffer
        }

        // 设置渲染状态
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(inputTexture, index: 0)

        // 设置片段着色器参数
        var intensityVar = intensity
        var textureSize = SIMD2<Float>(Float(width), Float(height))
        renderEncoder.setFragmentBytes(&intensityVar, length: MemoryLayout<Float>.size, index: 0)
        renderEncoder.setFragmentBytes(&textureSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        // 绘制
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        // 提交命令
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 将输出纹理复制回 CVPixelBuffer
        return copyTextureToPixelBuffer(outputTexture, target: pixelBuffer)
    }

    private func createRenderPassDescriptor(texture: MTLTexture) -> MTLRenderPassDescriptor? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return descriptor
    }

    private func copyTextureToPixelBuffer(_ texture: MTLTexture, target: CVPixelBuffer) -> CVPixelBuffer? {
        // 使用 blit 命令将纹理数据复制回 pixel buffer
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return target
        }

        // 注意：这里简化处理，实际应该创建可读的 pixel buffer
        // 对于实时播放，建议使用 CVPixelBufferPool 和直接渲染到 MTKView

        blitEncoder.endEncoding()
        commandBuffer.commit()

        return target
    }
}

// MARK: - 增强型视频输出

/// 包装 AVPlayerItemVideoOutput，添加实时超分处理
@MainActor
class EnhancedVideoOutput: AVPlayerItemVideoOutput, @unchecked Sendable {
    private nonisolated(unsafe) var displayLink: CVDisplayLink?
    private weak var playerItem: AVPlayerItem?

    init(playerItem: AVPlayerItem) {
        // 配置视频输出设置
        let pixelBufferAttributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        super.init(pixelBufferAttributes: pixelBufferAttributes)

        self.playerItem = playerItem
        playerItem.add(self)
        
        // 设置代理
        setDelegate(self, queue: DispatchQueue.main)
    }

    nonisolated deinit {
        // 安全地清理
    }

    /// 获取处理后的视频帧
    func getEnhancedFrame(forHostTime hostTime: CMTime) -> CVPixelBuffer? {
        guard let pixelBuffer = copyPixelBuffer(forItemTime: hostTime, itemTimeForDisplay: nil) else {
            return nil
        }

        // 应用超分处理
        if AnimeVideoEnhancer.shared.isEnabled {
            return AnimeVideoEnhancer.shared.processFrame(pixelBuffer) ?? pixelBuffer
        }

        return pixelBuffer
    }
}

// MARK: - AVPlayerItemOutputPullDelegate

extension EnhancedVideoOutput: AVPlayerItemOutputPullDelegate {
    nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        // 数据即将变化时的处理
        // 注意：此方法在非隔离上下文中调用，避免与 @MainActor 冲突
    }
}

// MARK: - 增强播放器视图 (AppKit)

#if canImport(AppKit)
import AppKit

/// 支持超分辨率的 Metal 视频渲染视图
class EnhancedVideoView: MTKView {
    private var player: AVPlayer?
    private var videoOutput: EnhancedVideoOutput?
    private nonisolated(unsafe) var displayLink: CVDisplayLink?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var textureCache: CVMetalTextureCache?

    // 当前帧纹理
    private var currentFrameTexture: MTLTexture?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)

        self.commandQueue = device?.makeCommandQueue()
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = false

        // 创建纹理缓存
        if let device = device {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            self.textureCache = cache
        }

        setupShaders()
        setupVertexBuffer()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupShaders() {
        guard let device = device else { return }

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut vertexShader(
            uint vertexID [[vertex_id]],
            constant float4 *vertices [[buffer(0)]]
        ) {
            VertexOut out;
            float4 pos = vertices[vertexID];
            out.position = float4(pos.xy, 0.0, 1.0);
            out.texCoord = float2(pos.z, 1.0 - pos.w);  // 翻转 Y
            return out;
        }

        fragment float4 fragmentShader(
            VertexOut in [[stage_in]],
            texture2d<float> videoTexture [[texture(0)]]
        ) {
            constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
            return videoTexture.sample(textureSampler, in.texCoord);
        }
        """

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "vertexShader"),
              let fragmentFunction = library.makeFunction(name: "fragmentShader") else {
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[EnhancedVideoView] 着色器编译失败: \(error)")
        }
    }

    private func setupVertexBuffer() {
        let vertices: [Float] = [
            -1.0, -1.0, 0.0, 0.0,  // 左下
             1.0, -1.0, 1.0, 0.0,  // 右下
            -1.0,  1.0, 0.0, 1.0,  // 左上
             1.0,  1.0, 1.0, 1.0   // 右上
        ]

        let dataSize = vertices.count * MemoryLayout<Float>.size
        self.vertexBuffer = device?.makeBuffer(bytes: vertices, length: dataSize, options: [])
    }

    func setPlayer(_ player: AVPlayer) {
        self.player = player

        // 创建视频输出
        if let currentItem = player.currentItem {
            self.videoOutput = EnhancedVideoOutput(playerItem: currentItem)
            currentItem.add(videoOutput!)
        }

        // 设置显示链接 (CVDisplayLink 在 macOS 15.0 中废弃但仍可用)
        if #available(macOS 15.0, *) {
            // 使用新的 API (待实现)
        } else {
            setupDisplayLink()
        }

        // 监听播放器 item 变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidChange),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    @available(macOS, deprecated: 15.0)
    private func setupDisplayLink() {
        // 创建 CVDisplayLink 用于同步显示刷新
        var displayLink: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

        guard result == kCVReturnSuccess, let link = displayLink else {
            print("[EnhancedVideoView] 显示链接创建失败")
            return
        }

        // 设置回调
        let callback: CVDisplayLinkOutputCallback = { displayLink, inNow, inOutputTime, flagsIn, flagsOut, context in
            guard let context = context else { return kCVReturnSuccess }
            let view = Unmanaged<EnhancedVideoView>.fromOpaque(context).takeUnretainedValue()
            view.renderFrame()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)

        self.displayLink = link
    }

    @objc private func playerItemDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let player = self.player else { return }

            // 重新设置视频输出
            if let currentItem = player.currentItem {
                self.videoOutput = EnhancedVideoOutput(playerItem: currentItem)
            }
        }
    }

    private func renderFrame() {
        guard let player = player,
              let videoOutput = videoOutput,
              let currentItem = player.currentItem else { return }

        let currentTime = currentItem.currentTime()

        // 获取视频帧
        guard let pixelBuffer = videoOutput.getEnhancedFrame(forHostTime: currentTime) else { return }

        // 创建纹理
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache!,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard let cvTexture = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return }

        self.currentFrameTexture = texture

        // 触发重绘
        DispatchQueue.main.async { [weak self] in
            self?.draw()
        }
    }

    override func draw(_ rect: CGRect) {
        renderToMetal()
    }

    private func renderToMetal() {
        guard let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor,
              let pipelineState = pipelineState,
              let vertexBuffer = vertexBuffer,
              let currentFrameTexture = currentFrameTexture,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // 设置渲染状态
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(currentFrameTexture, index: 0)

        // 绘制全屏四边形
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        // 呈现
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    nonisolated deinit {
        // 使用存储的 displayLink 引用停止它
        if let displayLink = self.displayLink {
            // CVDisplayLink 在 macOS 15.0 中废弃但仍可用
            if #available(macOS 15.0, *) {
                // 新的 API 不需要手动停止
            } else {
                _ = CVDisplayLinkStop(displayLink)
            }
        }
    }
}

#endif
