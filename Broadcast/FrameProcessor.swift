import CoreMedia
import ImageIO
import ReplayKit
import UniformTypeIdentifiers
import VideoToolbox

/// Готовит кадр экрана для телевизора: уменьшает и ставит вертикально.
/// Буферы берутся из пулов, а не переиспользуются: кодировщик H.264 держит кадр, пока сжимает его.
final class FrameProcessor {
    private let maxSide = 1280

    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var scaledPool = BufferPool()
    private var rotatedPool = BufferPool()

    init() {
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        VTPixelRotationSessionCreate(nil, &rotation)
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        if let rotation { VTPixelRotationSessionInvalidate(rotation) }
    }

    func process(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let transfer, let rotation else { return nil }

        // Уменьшаем и переводим из YUV в BGRA за один проход.
        // Стороны кратны 16: такой кадр без сюрпризов декодирует любой аппаратный декодер H.264.
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        let w = Self.multipleOf16(Double(width) * scale)
        let h = Self.multipleOf16(Double(height) * scale)
        guard let scaled = scaledPool.buffer(width: w, height: h),
              VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr else {
            return nil
        }

        // Буфер экрана всегда портретный. Если телефон повёрнут, поворачиваем картинку,
        // чтобы на телевизоре она стояла правильно.
        guard let angle = Self.rotationAngle(of: sampleBuffer) else { return scaled }
        let sideways = angle == kVTRotation_CW90 || angle == kVTRotation_CCW90
        guard let rotated = rotatedPool.buffer(width: sideways ? h : w, height: sideways ? w : h),
              VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: angle) == noErr,
              VTPixelRotationSessionRotateImage(rotation, scaled, rotated) == noErr else {
            return nil
        }
        return rotated
    }

    private static func multipleOf16(_ value: Double) -> Int {
        max(16, Int((value / 16).rounded()) * 16)
    }

    /// Ориентация из ReplayKit задана в смысле EXIF: сколько повернуть кадр, чтобы он встал прямо.
    private static func rotationAngle(of sampleBuffer: CMSampleBuffer) -> CFString? {
        guard let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else { return nil }
        switch orientation {
        case .right: return kVTRotation_CW90
        case .left: return kVTRotation_CCW90
        case .down: return kVTRotation_180
        default: return nil
        }
    }
}

/// Пул буферов BGRA одного размера. При смене размера, например при повороте телефона, пересоздаётся.
private struct BufferPool {
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    mutating func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || width != self.width || height != self.height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            self.width = width
            self.height = height
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}

/// Запасной формат для телевизоров, где браузер не умеет показывать H.264: каждый кадр отдельным JPEG.
enum JPEGEncoder {
    static func encode(_ buffer: CVPixelBuffer, quality: Double = 0.6) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
