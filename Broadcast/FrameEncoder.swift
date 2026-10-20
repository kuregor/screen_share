import CoreMedia
import ImageIO
import ReplayKit
import UniformTypeIdentifiers
import VideoToolbox

/// Готовит кадр экрана для телевизора: уменьшает, ставит вертикально и сжимает в JPEG.
/// Расширению трансляции iOS даёт около 50 МБ памяти, поэтому промежуточные буферы переиспользуются.
final class FrameEncoder {
    private let maxSide = 1280
    private let minInterval = 1.0 / 20
    private let quality = 0.6

    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var scaled: CVPixelBuffer?
    private var rotated: CVPixelBuffer?
    private var lastEncoded: TimeInterval = 0

    init() {
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        VTPixelRotationSessionCreate(nil, &rotation)
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        if let rotation { VTPixelRotationSessionInvalidate(rotation) }
    }

    /// Возвращает JPEG или nil, если кадр пропущен из-за ограничения частоты или ошибки.
    func encode(_ sampleBuffer: CMSampleBuffer) -> Data? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastEncoded >= minInterval,
              let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let transfer, let rotation else { return nil }

        // Уменьшаем и переводим из YUV в BGRA за один проход.
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        let w = Int(Double(width) * scale) & ~1
        let h = Int(Double(height) * scale) & ~1
        scaled = Self.reuse(scaled, width: w, height: h)
        guard let scaled, VTPixelTransferSessionTransferImage(transfer, from: source, to: scaled) == noErr else {
            return nil
        }

        // Буфер экрана всегда портретный. Если телефон повёрнут, поворачиваем картинку,
        // чтобы на телевизоре она стояла правильно.
        var output = scaled
        if let angle = Self.rotationAngle(of: sampleBuffer) {
            let sideways = angle == kVTRotation_CW90 || angle == kVTRotation_CCW90
            rotated = Self.reuse(rotated, width: sideways ? h : w, height: sideways ? w : h)
            guard let rotated,
                  VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: angle) == noErr,
                  VTPixelRotationSessionRotateImage(rotation, scaled, rotated) == noErr else {
                return nil
            }
            output = rotated
        }

        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(output, options: nil, imageOut: &image)
        guard let image else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        lastEncoded = now
        return data as Data
    }

    private static func reuse(_ buffer: CVPixelBuffer?, width: Int, height: Int) -> CVPixelBuffer? {
        if let buffer, CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height {
            return buffer
        }
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        return created
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
