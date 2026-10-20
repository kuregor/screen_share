import VideoToolbox

/// Сжимает кадры в H.264 аппаратным кодировщиком телефона.
///
/// На выходе Annex B: NAL-блоки со стартовыми кодами, в ключевых кадрах ещё SPS и PPS.
/// Такой поток страница телевизора отдаёт jmuxer, а тот — встроенному видеоплееру браузера.
/// По сравнению с MJPEG это в несколько раз меньше трафика, а декодирует телевизор аппаратно.
final class H264Encoder {
    /// Готовый кадр, признак ключевого кадра и время кадра в миллисекундах.
    /// Вызывается из внутренней очереди кодировщика.
    var onFrame: ((Data, Bool, UInt32) -> Void)?

    private let queue = DispatchQueue(label: "H264Encoder")
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var lastTime = CMTime.invalid
    private let startCode = Data([0, 0, 0, 1])

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    func encode(_ buffer: CVPixelBuffer, time: CMTime, forceKeyFrame: Bool = false) {
        queue.async { self.encodeNow(buffer, time: time, forceKeyFrame: forceKeyFrame) }
    }

    private func encodeNow(_ buffer: CVPixelBuffer, time: CMTime, forceKeyFrame: Bool) {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        // Телефон повернули: разрешение сменилось, нужен новый сеанс. Он начнётся с ключевого кадра.
        if session == nil || w != width || h != height {
            makeSession(width: w, height: h)
        }
        guard let session else { return }

        // Повторно сжатый старый кадр не должен уйти в прошлое относительно уже отправленных.
        var time = time
        if lastTime.isValid, time <= lastTime {
            time = lastTime + CMTime(value: 1, timescale: 1000)
        }
        lastTime = time

        let properties = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time,
                                        duration: .invalid, frameProperties: properties,
                                        infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.queue.async { self.deliver(sample) }
        }
    }

    private func makeSession(width: Int, height: Int) {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { return }

        // Без B-кадров: каждый кадр можно показать сразу, задержка минимальная.
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: 4_000_000,
            kVTCompressionPropertyKey_DataRateLimits: [6_000_000 / 8, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
        ]
        VTSessionSetProperties(created, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
        self.width = width
        self.height = height
    }

    private func deliver(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)

        var output = Data()
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            // Индекс 0 — SPS, 1 — PPS.
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if status == noErr, let pointer {
                    output.append(startCode)
                    output.append(pointer, count: size)
                }
            }
        }

        // Кодировщик пишет AVCC: перед каждым NAL-блоком его длина в 4 байтах. Меняем длины на стартовые коды.
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copied == noErr else { return }

        var offset = 0
        while offset + 4 <= length {
            let nalLength = Int(avcc[offset]) << 24 | Int(avcc[offset + 1]) << 16
                | Int(avcc[offset + 2]) << 8 | Int(avcc[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            output.append(startCode)
            output.append(avcc[offset..<offset + nalLength])
            offset += nalLength
        }

        let millis = CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000
        onFrame?(output, isKey, UInt32(truncatingIfNeeded: Int64(millis)))
    }
}
