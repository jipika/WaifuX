import Foundation
import Metal
import CoreVideo

final class FrameInterpolationMetalInterpolator: @unchecked Sendable {
    static let shared = FrameInterpolationMetalInterpolator()

    private struct WarpUniforms {
        var width: UInt32
        var height: UInt32
        var alpha: Float
        var inverseAlpha: Float
    }

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            self.device = nil
            self.commandQueue = nil
            self.pipelineState = nil
            self.textureCache = nil
            frameInterpolationDebugPrint("Metal 光流插帧：Metal 设备不可用，GPU-only 补帧将失败。")
            return
        }

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct WarpUniforms {
            uint width;
            uint height;
            float alpha;
            float inverseAlpha;
        };

        kernel void opticalFlowWarpKernel(
            texture2d<float, access::sample> currentTexture [[texture(0)]],
            texture2d<float, access::sample> nextTexture [[texture(1)]],
            texture2d<float, access::read> flowTexture [[texture(2)]],
            texture2d<float, access::write> outputTexture [[texture(3)]],
            constant WarpUniforms &uniforms [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= uniforms.width || gid.y >= uniforms.height) {
                return;
            }

            constexpr sampler pixelSampler(coord::pixel, address::clamp_to_edge, filter::linear);
            float2 flow = flowTexture.read(gid).rg;
            float2 baseCoord = float2(gid) + float2(0.5, 0.5);
            float2 currentCoord = baseCoord + flow * uniforms.alpha;
            float2 nextCoord = baseCoord - flow * uniforms.inverseAlpha;

            float4 currentColor = currentTexture.sample(pixelSampler, currentCoord);
            float4 nextColor = nextTexture.sample(pixelSampler, nextCoord);
            float4 mixedColor = mix(currentColor, nextColor, uniforms.alpha);
            outputTexture.write(saturate(mixedColor), gid);
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let function = library.makeFunction(name: "opticalFlowWarpKernel") else {
                self.device = nil
                self.commandQueue = nil
                self.pipelineState = nil
                self.textureCache = nil
                frameInterpolationDebugPrint("Metal 光流插帧：找不到 opticalFlowWarpKernel，GPU-only 补帧将失败。")
                return
            }

            var cache: CVMetalTextureCache?
            let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            guard cacheStatus == kCVReturnSuccess, let cache else {
                self.device = nil
                self.commandQueue = nil
                self.pipelineState = nil
                self.textureCache = nil
                frameInterpolationDebugPrint("Metal 光流插帧：创建 CVMetalTextureCache 失败，状态=\(cacheStatus)，GPU-only 补帧将失败。")
                return
            }

            self.device = device
            self.commandQueue = commandQueue
            self.pipelineState = try device.makeComputePipelineState(function: function)
            self.textureCache = cache
            frameInterpolationDebugPrint("Metal 光流插帧：GPU warp 管线已启用。")
        } catch {
            self.device = nil
            self.commandQueue = nil
            self.pipelineState = nil
            self.textureCache = nil
            frameInterpolationDebugPrint("Metal 光流插帧：着色器编译失败：\(error.localizedDescription)，GPU-only 补帧将失败。")
        }
    }

    func interpolate(
        current: CVPixelBuffer,
        next: CVPixelBuffer,
        flow: CVPixelBuffer,
        alpha: Double,
        output: CVPixelBuffer
    ) -> Bool {
        guard let commandQueue,
              let pipelineState,
              let textureCache else {
            return false
        }

        let width = CVPixelBufferGetWidth(current)
        let height = CVPixelBufferGetHeight(current)
        guard width == CVPixelBufferGetWidth(next),
              height == CVPixelBufferGetHeight(next),
              width == CVPixelBufferGetWidth(flow),
              height == CVPixelBufferGetHeight(flow),
              width == CVPixelBufferGetWidth(output),
              height == CVPixelBufferGetHeight(output),
              CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(next) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float else {
            return false
        }

        guard let currentTexture = makeTexture(from: current, pixelFormat: .bgra8Unorm, width: width, height: height, cache: textureCache),
              let nextTexture = makeTexture(from: next, pixelFormat: .bgra8Unorm, width: width, height: height, cache: textureCache),
              let flowTexture = makeTexture(from: flow, pixelFormat: .rg32Float, width: width, height: height, cache: textureCache),
              let outputTexture = makeTexture(from: output, pixelFormat: .bgra8Unorm, width: width, height: height, cache: textureCache) else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        var uniforms = WarpUniforms(
            width: UInt32(width),
            height: UInt32(height),
            alpha: Float(alpha),
            inverseAlpha: Float(1.0 - alpha)
        )

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(nextTexture, index: 1)
        encoder.setTexture(flowTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<WarpUniforms>.stride, index: 0)

        let threadExecutionWidth = pipelineState.threadExecutionWidth
        let maxThreads = max(1, pipelineState.maxTotalThreadsPerThreadgroup / max(1, threadExecutionWidth))
        let threadsPerThreadgroup = MTLSize(width: threadExecutionWidth, height: maxThreads, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        CVMetalTextureCacheFlush(textureCache, 0)
        return commandBuffer.status == .completed && commandBuffer.error == nil
    }

    func flushTextureCache() {
        guard let textureCache else { return }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        cache: CVMetalTextureCache
    ) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return texture
    }
}
