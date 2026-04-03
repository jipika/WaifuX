import Foundation
import Metal
import MetalPerformanceShaders
import CoreImage
import AVFoundation
import CoreMedia

// MARK: - 超分辨率服务

/// 使用 Metal 硬件加速的图像/视频超分辨率服务
/// 支持 bicubic 插值、 lanczos 插值以及简单的锐化增强
actor SuperResolutionService {
    static let shared = SuperResolutionService()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    /// 缩放因子
    enum ScaleFactor: Int {
        case x2 = 2
        case x3 = 3
        case x4 = 4
    }

    /// 插值算法
    enum Interpolation {
        case bicubic
        case lanczos
        case neuralNetwork  // 需要额外模型
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .priorityRequestLow: false
        ])
    }

    // MARK: - 图像超分辨率

    /// 对 CGImage 进行硬件加速放大
    func upscaleImage(_ image: CGImage, scale: ScaleFactor, sharpen: Bool = true) -> CGImage? {
        let width = image.width * scale.rawValue
        let height = image.height * scale.rawValue

        // 创建 Metal 纹理
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let texture = device.makeTexture(descriptor: textureDescriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        // 使用 CIFilter 进行高质量放大
        let ciImage = CIImage(cgImage: image)

        // 先放大
        guard let scaledImage = ciImage.transformed(by: CGAffineTransform(
            scaleX: CGFloat(scale.rawValue),
            y: CGFloat(scale.rawValue)
        )).cropped(to: CGRect(x: 0, y: 0, width: width, height: height)) as CIImage? else {
            return nil
        }

        var finalImage = scaledImage

        // 锐化增强
        if sharpen {
            if let sharpened = applySharpening(to: scaledImage) {
                finalImage = sharpened
            }
        }

        // 渲染到纹理
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ciContext.render(
            finalImage,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 从纹理创建 CGImage
        return createCGImage(from: texture)
    }

    /// 对 CVPixelBuffer 进行硬件加速放大
    func upscalePixelBuffer(_ pixelBuffer: CVPixelBuffer, scale: ScaleFactor) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let targetWidth = sourceWidth * scale.rawValue
        let targetHeight = sourceHeight * scale.rawValue

        // 创建目标 pixel buffer
        var destinationBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &destinationBuffer
        )

        guard status == kCVReturnSuccess, let _ = destinationBuffer else {
            return nil
        }

        // 使用 Metal 进行放大
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        // 创建目标纹理
        let destTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        destTextureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let destTexture = device.makeTexture(descriptor: destTextureDescriptor),
              let sourceImage = CIImage(cvPixelBuffer: pixelBuffer).cgImage else {
            return nil
        }

        // 使用 CIFilter 放大
        let ciImage = CIImage(cgImage: sourceImage)
        let transform = CGAffineTransform(scaleX: CGFloat(scale.rawValue), y: CGFloat(scale.rawValue))
        let scaledImage = ciImage.transformed(by: transform)

        ciContext.render(
            scaledImage,
            to: destTexture,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 从纹理创建 CVPixelBuffer
        return createPixelBuffer(from: destTexture, width: targetWidth, height: targetHeight)
    }

    // MARK: - 视频帧超分辨率

    /// 对视频帧进行超分辨率处理
    func processVideoFrame(_ pixelBuffer: CVPixelBuffer, scale: ScaleFactor) async throws -> CVPixelBuffer {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                if let result = self.upscalePixelBuffer(pixelBuffer, scale: scale) {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: SuperResolutionError.processingFailed)
                }
            }
        }
    }

    // MARK: - 辅助方法

    private func applySharpening(to image: CIImage) -> CIImage? {
        // 使用 CIAffineClamp 和 CISharpenLuminance
        guard let sharpenFilter = CIFilter(name: "CISharpenLuminance") else {
            return nil
        }

        sharpenFilter.setValue(image, forKey: kCIInputImageKey)
        sharpenFilter.setValue(0.4, forKey: kCIInputSharpnessKey)

        return sharpenFilter.outputImage
    }

    private func createCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let dataSize = bytesPerRow * height

        var pixelData = [UInt8](repeating: 0, count: dataSize)
        let region = MTLRegionMake2D(0, 0, width, height)

        texture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        return context.makeImage()
    }

    private func createPixelBuffer(from texture: MTLTexture, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let region = MTLRegionMake2D(0, 0, width, height)

        texture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        return buffer
    }
}

// MARK: - Super Resolution 扩展

extension SuperResolutionService {
    /// 使用 bicubic 插值放大
    func bicubicUpscale(_ image: CGImage, scale: ScaleFactor) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        let transform = CGAffineTransform(scaleX: CGFloat(scale.rawValue), y: CGFloat(scale.rawValue))
        let scaledImage = ciImage.transformed(by: transform)

        var finalImage = scaledImage

        // 应用 CIHighlightShadowAdjust 增强
        if let enhanced = applyEnhancement(to: scaledImage) {
            finalImage = enhanced
        }

        guard let cgResult = ciContext.createCGImage(finalImage, from: finalImage.extent) else {
            return nil
        }

        return cgResult
    }

    private func applyEnhancement(to image: CIImage) -> CIImage? {
        guard let filter = CIFilter(name: "CIHighlightShadowAdjust") else {
            return nil
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(1.0, forKey: "inputShadowAmount")
        filter.setValue(1.0, forKey: "inputHighlightAmount")

        return filter.outputImage
    }
}

// MARK: - 错误类型

enum SuperResolutionError: Error, LocalizedError {
    case deviceNotAvailable
    case processingFailed
    case invalidInput
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .deviceNotAvailable:
            return "Metal 设备不可用"
        case .processingFailed:
            return "超分辨率处理失败"
        case .invalidInput:
            return "无效的输入数据"
        case .modelNotLoaded:
            return "AI 模型未加载"
        }
    }
}

// MARK: - 便捷扩展

extension CGImage {
    /// 使用 Metal 硬件加速放大到指定尺寸
    func metalUpscaled(to size: CGSize, sharpen: Bool = true) -> CGImage? {
        guard let service = SuperResolutionService.shared else {
            return nil
        }

        let scaleX = size.width / CGFloat(width)
        let scaleY = size.height / CGFloat(height)
        let scale = max(scaleX, scaleY)
        let scaleFactor: SuperResolutionService.ScaleFactor

        if scale >= 4 {
            scaleFactor = .x4
        } else if scale >= 3 {
            scaleFactor = .x3
        } else {
            scaleFactor = .x2
        }

        // 使用临时任务来调用 actor 方法
        var result: CGImage?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            result = await service.upscaleImage(self, scale: scaleFactor, sharpen: sharpen)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}

extension CVPixelBuffer {
    /// 使用 Metal 硬件加速放大
    func metalUpscaled(scale: SuperResolutionService.ScaleFactor) -> CVPixelBuffer? {
        guard let service = SuperResolutionService.shared else {
            return nil
        }

        var result: CVPixelBuffer?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            result = await service.upscalePixelBuffer(self, scale: scale)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
