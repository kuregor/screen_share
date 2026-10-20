import CoreMedia
import ImageIO
import ReplayKit
import UniformTypeIdentifiers
import VideoToolbox

/// Готовит кадры экрана для телевизора.
///
/// Для H.264 кадр всегда горизонтальный, до 1920 px по ширине: декодеры телевизоров LG
/// рассчитаны на 1920×1080 и вертикальное видео 880×1920 не показывают. Портретный экран
/// телефона поворачивается на четверть оборота, а страница телевизора поворачивает его обратно
/// по флагу. Кадр остаётся в YUV (NV12): это вдвое компактнее BGRA, а расширению трансляции
/// iOS даёт всего около 50 МБ памяти. Если поворот в NV12 не поддерживается, используется
/// BGRA с меньшим разрешением.
///
/// Для запасного MJPEG кадр уменьшается до 1280 px и поворачивается здесь, в BGRA.
///
/// Буферы берутся из пулов, а не переиспользуются: кодировщик H.264 держит кадр, пока сжимает его.
final class FrameProcessor {
    private let videoMaxSide = 1920
    private let fallbackVideoMaxSide = 1280
    private let jpegMaxSide = 1280

    private var transfer: VTPixelTransferSession?
    private var rotation: VTPixelRotationSession?
    private var nv12RotationWorks = true
    private var videoPool = BufferPool(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    private var videoRotatedPool = BufferPool(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    private var fallbackVideoPool = BufferPool(format: kCVPixelFormatType_32BGRA)
    private var fallbackRotatedPool = BufferPool(format: kCVPixelFormatType_32BGRA)
    private var jpegPool = BufferPool(format: kCVPixelFormatType_32BGRA)
    private var rotatedPool = BufferPool(format: kCVPixelFormatType_32BGRA)

    init() {
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        VTPixelRotationSessionCreate(nil, &rotation)
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        if let rotation { VTPixelRotationSessionInvalidate(rotation) }
    }

    /// Горизонтальный кадр для H.264 и число четвертей оборота по часовой,
    /// на которое его нужно повернуть при показе.
    func videoFrame(_ sampleBuffer: CMSampleBuffer) -> (buffer: CVPixelBuffer, quarterTurns: UInt8)? {
        let needed = Self.quarterTurns(of: sampleBuffer)
        if nv12RotationWorks, let frame = scaled(sampleBuffer, maxSide: videoMaxSide, pool: &videoPool) {
            if let landscape = makeLandscape(frame, needed: needed, pool: &videoRotatedPool) {
                return landscape
            }
            nv12RotationWorks = false
        }
        guard let frame = scaled(sampleBuffer, maxSide: fallbackVideoMaxSide, pool: &fallbackVideoPool) else {
            return nil
        }
        return makeLandscape(frame, needed: needed, pool: &fallbackRotatedPool)
    }

    /// Кадр для MJPEG, уже повёрнутый как надо.
    func jpegFrame(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard let frame = scaled(sampleBuffer, maxSide: jpegMaxSide, pool: &jpegPool) else { return nil }
        let turns = Self.quarterTurns(of: sampleBuffer)
        return turns == 0 ? frame : rotate(frame, turns: turns, pool: &rotatedPool)
    }

    /// Портретный кадр кладём набок поворотом по часовой. Тогда для показа его нужно повернуть
    /// на четверть оборота меньше, чем требовала ориентация телефона.
    private func makeLandscape(_ frame: CVPixelBuffer, needed: UInt8,
                               pool: inout BufferPool) -> (buffer: CVPixelBuffer, quarterTurns: UInt8)? {
        guard CVPixelBufferGetHeight(frame) > CVPixelBufferGetWidth(frame) else { return (frame, needed) }
        guard let rotated = rotate(frame, turns: 1, pool: &pool) else { return nil }
        return (rotated, (needed + 3) % 4)
    }

    private func rotate(_ frame: CVPixelBuffer, turns: UInt8, pool: inout BufferPool) -> CVPixelBuffer? {
        guard let rotation else { return nil }
        let angle = [kVTRotation_0, kVTRotation_CW90, kVTRotation_180, kVTRotation_CCW90][Int(turns % 4)]
        let w = CVPixelBufferGetWidth(frame)
        let h = CVPixelBufferGetHeight(frame)
        let sideways = turns % 2 == 1
        guard let rotated = pool.buffer(width: sideways ? h : w, height: sideways ? w : h),
              VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: angle) == noErr,
              VTPixelRotationSessionRotateImage(rotation, frame, rotated) == noErr else {
            return nil
        }
        return rotated
    }

    /// Уменьшает кадр и переводит в формат пула за один проход.
    /// Стороны кратны 16: такой кадр без сюрпризов декодирует любой аппаратный декодер H.264.
    private func scaled(_ sampleBuffer: CMSampleBuffer, maxSide: Int, pool: inout BufferPool) -> CVPixelBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer), let transfer else { return nil }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        guard let output = pool.buffer(width: Self.multipleOf16(Double(width) * scale),
                                       height: Self.multipleOf16(Double(height) * scale)),
              VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr else {
            return nil
        }
        return output
    }

    private static func multipleOf16(_ value: Double) -> Int {
        max(16, Int((value / 16).rounded()) * 16)
    }

    /// Буфер экрана всегда портретный. Если телефон повёрнут, картинку нужно повернуть при показе.
    /// Направления проверены на iPhone: с поворотом по EXIF (.right — по часовой)
    /// картинка в альбомной ориентации была вверх ногами.
    private static func quarterTurns(of sampleBuffer: CMSampleBuffer) -> UInt8 {
        guard let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                          attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else { return 0 }
        switch orientation {
        case .left: return 1
        case .down: return 2
        case .right: return 3
        default: return 0
        }
    }
}

/// Пул буферов одного размера и формата. При смене размера пересоздаётся.
private struct BufferPool {
    let format: OSType
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    init(format: OSType) {
        self.format = format
    }

    mutating func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || width != self.width || height != self.height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
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
