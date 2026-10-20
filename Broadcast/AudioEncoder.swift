import AVFoundation

/// Сжимает звук приложений (то, что играет на телефоне) в AAC.
///
/// Каждый пакет AAC (1024 сэмпла) получает заголовок ADTS: так пакет самодостаточен,
/// и jmuxer на странице телевизора узнаёт из него частоту и число каналов.
final class AudioEncoder {
    /// Готовый кадр ADTS и время в миллисекундах. Вызывается из внутренней очереди.
    var onPacket: ((Data, UInt32) -> Void)?

    private let queue = DispatchQueue(label: "AudioEncoder")
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var timestamp: UInt32 = 0

    /// Копирует звук из буфера ReplayKit сразу, а сжимает в своей очереди.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let input = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: pcm.mutableAudioBufferList) == noErr else {
            return
        }
        let millis = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000
        let time = UInt32(truncatingIfNeeded: Int64(millis))

        queue.async {
            if self.converter?.inputFormat != input {
                self.makeConverter(for: input)
            }
            self.timestamp = time
            self.pending.append(pcm)
            // Если сеть или кодировщик не успевают, старый звук не копим.
            if self.pending.count > 50 { self.pending.removeFirst(self.pending.count - 50) }
            self.drain()
        }
    }

    private func makeConverter(for input: AVAudioFormat) {
        converter = nil
        outputFormat = nil
        pending.removeAll()

        // AAC-LC с той же частотой, не больше двух каналов.
        let channels = min(2, input.channelCount)
        var description = AudioStreamBasicDescription(
            mSampleRate: input.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        guard let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: input, to: output) else { return }
        converter.bitRate = channels == 1 ? 64_000 : 128_000
        converter.downmix = input.channelCount > 2
        self.converter = converter
        outputFormat = output
    }

    private func drain() {
        guard let converter, let outputFormat else { return }
        while true {
            let output = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 8,
                                                 maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard !self.pending.isEmpty else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            emit(output, format: outputFormat)
            if status != .haveData || output.packetCount == 0 { break }
        }
    }

    private func emit(_ buffer: AVAudioCompressedBuffer, format: AVAudioFormat) {
        guard let descriptions = buffer.packetDescriptions else { return }
        let bytes = buffer.data.assumingMemoryBound(to: UInt8.self)
        for index in 0..<Int(buffer.packetCount) {
            let description = descriptions[index]
            let size = Int(description.mDataByteSize)
            var packet = Self.adtsHeader(payloadSize: size, sampleRate: format.sampleRate,
                                         channels: Int(format.channelCount))
            packet.append(bytes + Int(description.mStartOffset), count: size)
            onPacket?(packet, timestamp)
        }
    }

    /// Заголовок ADTS для AAC-LC без контрольной суммы (7 байт).
    private static func adtsHeader(payloadSize: Int, sampleRate: Double, channels: Int) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let rateIndex = rates.firstIndex(of: sampleRate) ?? 4
        let length = payloadSize + 7
        let profile = 1 // AAC-LC: object type 2, в заголовке пишется на единицу меньше
        return Data([
            0xFF,
            0xF1,
            UInt8(profile << 6 | rateIndex << 2 | channels >> 2),
            UInt8((channels & 3) << 6 | length >> 11),
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 7) << 5 | 0x1F),
            0xFC,
        ])
    }
}
