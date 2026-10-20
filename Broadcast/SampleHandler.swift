import ReplayKit

/// Точка входа расширения: ReplayKit отдаёт сюда кадры экрана, пока идёт вещание.
final class SampleHandler: RPBroadcastSampleHandler {
    private let processor = FrameProcessor()
    private let h264 = H264Encoder()
    private var server: StreamServer?

    // Обработка идёт и из потока ReplayKit, и по запросу ключевого кадра, поэтому под замком.
    private let lock = NSLock()
    private var latestSample: CMSampleBuffer?
    private var lastVideo: TimeInterval = 0
    private var lastJPEG: TimeInterval = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let address = LocalNetwork.wifiAddress() else {
            finish("Подключи телефон к Wi-Fi и начни вещание снова.")
            return
        }
        let server = StreamServer(address: address)
        server.onFailure = { [weak self] error in
            self?.finish("Не удалось открыть порт: \(error.localizedDescription)")
        }
        server.onKeyFrameNeeded = { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { self?.sendKeyFrame() }
        }
        h264.onFrame = { [weak server] frame, isKey, timestamp in
            server?.broadcastVideo(frame, isKey: isKey, timestamp: timestamp)
        }
        do {
            try server.start()
        } catch {
            finish("Не удалось запустить сервер: \(error.localizedDescription)")
            return
        }
        self.server = server
    }

    override func broadcastFinished() {
        server?.stop()
        server = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let server else { return }
        lock.lock()
        defer { lock.unlock() }
        latestSample = sampleBuffer

        // Кадры сжимаем, только когда телевизор подключён: так расширение не тратит батарею впустую.
        let now = ProcessInfo.processInfo.systemUptime
        let wantsVideo = server.hasVideoViewers && now - lastVideo >= 1.0 / 30
        let wantsJPEG = server.hasJPEGViewers && now - lastJPEG >= 1.0 / 20
        guard wantsVideo || wantsJPEG, let frame = processor.process(sampleBuffer) else { return }

        if wantsVideo {
            lastVideo = now
            h264.encode(frame, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        if wantsJPEG, let jpeg = JPEGEncoder.encode(frame) {
            lastJPEG = now
            server.broadcast(jpeg)
        }
    }

    /// Новому зрителю нужен ключевой кадр. Если экран не меняется, ReplayKit новых кадров не шлёт,
    /// поэтому заново сжимаем последний полученный.
    private func sendKeyFrame() {
        lock.lock()
        defer { lock.unlock() }
        guard let sample = latestSample, let frame = processor.process(sample) else { return }
        h264.encode(frame, time: CMSampleBufferGetPresentationTimeStamp(sample), forceKeyFrame: true)
    }

    private func finish(_ message: String) {
        finishBroadcastWithError(NSError(domain: "ScreenShare", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
