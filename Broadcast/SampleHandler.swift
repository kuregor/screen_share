import ReplayKit

/// Точка входа расширения: ReplayKit отдаёт сюда кадры экрана, пока идёт вещание.
final class SampleHandler: RPBroadcastSampleHandler {
    private let processor = FrameProcessor()
    private let h264 = H264Encoder()
    private let audio = AudioEncoder()

    // Ссылку на сервер читают поток ReplayKit и сеть, а меняют старт и остановка вещания.
    private let serverLock = NSLock()
    private var currentServer: StreamServer?
    private var server: StreamServer? {
        get {
            serverLock.lock()
            defer { serverLock.unlock() }
            return currentServer
        }
        set {
            serverLock.lock()
            currentServer = newValue
            serverLock.unlock()
        }
    }

    // Обработка кадров идёт и из потока ReplayKit, и по запросу ключевого кадра, поэтому под замком.
    private let lock = NSLock()
    private var latestSample: CMSampleBuffer?
    private var videoLimiter = FrameLimiter(fps: QualityControl.maxFps)
    private var limiterFps = QualityControl.maxFps
    private var jpegLimiter = FrameLimiter(fps: 20)

    // Ключевые кадры и подстройка качества меняются из сетевой очереди, поэтому отдельный замок:
    // сеть не должна ждать, пока обрабатывается кадр.
    private let controlLock = NSLock()
    private var quality = QualityControl()
    private var lastForcedKeyFrame: TimeInterval = -1
    private var keyFrameScheduled = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let address = LocalNetwork.wifiAddress() else {
            finish("Подключи телефон к Wi-Fi и начни вещание снова.")
            return
        }
        let server = StreamServer(address: address)
        server.onFailure = { [weak self] error in
            self?.finish("Не удалось открыть порт: \(error.localizedDescription)")
        }
        server.onKeyFrameNeeded = { [weak self] in self?.requestKeyFrame() }
        server.onCongestion = { [weak self] in self?.congestion() }
        server.onViewerStats = { [weak self] stats in self?.viewerStats(stats) }
        h264.onFrame = { [weak server] frame, isKey, timestamp, quarterTurns in
            server?.broadcastVideo(frame, isKey: isKey, timestamp: timestamp, quarterTurns: quarterTurns)
        }
        h264.setBitrate(quality.bitrate)
        audio.onPacket = { [weak server] packet, timestamp in
            server?.broadcastAudio(packet, timestamp: timestamp)
        }
        audio.onLog = { [weak server] message in server?.log(message) }
        do {
            try server.start()
        } catch {
            finish("Не удалось запустить сервер: \(error.localizedDescription)")
            return
        }
        self.server = server
    }

    override func broadcastFinished() {
        let server = self.server
        self.server = nil
        server?.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard let server else { return }
        switch sampleBufferType {
        case .video:
            processVideo(sampleBuffer, server: server)
        case .audioApp:
            if server.hasAudioViewers { audio.encode(sampleBuffer) }
        default:
            break
        }
    }

    private func processVideo(_ sampleBuffer: CMSampleBuffer, server: StreamServer) {
        let now = ProcessInfo.processInfo.systemUptime
        let (fps, raisedBitrate) = controlled { () -> (Double, Int?) in
            (quality.fps, quality.raiseIfCalm(now: now))
        }
        if let raisedBitrate {
            h264.setBitrate(raisedBitrate)
            server.log("сеть спокойна, битрейт \(raisedBitrate / 1_000_000) Мбит/с")
        }

        lock.lock()
        defer { lock.unlock() }
        latestSample = sampleBuffer
        if fps != limiterFps {
            videoLimiter = FrameLimiter(fps: fps)
            limiterFps = fps
        }

        // Кадры сжимаем, только когда телевизор подключён: так расширение не тратит батарею впустую.
        if server.hasVideoViewers, videoLimiter.allow(now), let video = processor.videoFrame(sampleBuffer) {
            h264.encode(video.buffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                        quarterTurns: video.quarterTurns)
        }
        if server.hasJPEGViewers, jpegLimiter.allow(now), let frame = processor.jpegFrame(sampleBuffer),
           let jpeg = JPEGEncoder.encode(frame) {
            server.broadcast(jpeg)
        }
    }

    /// Ключевой кадр — самый тяжёлый. Если просить его на каждый затор, затор только усиливается,
    /// поэтому не чаще раза в секунду; лишние запросы ждут ближайшего разрешённого момента.
    private func requestKeyFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay: TimeInterval? = controlled {
            if keyFrameScheduled { return nil }
            let wait = max(0, lastForcedKeyFrame + 1 - now)
            keyFrameScheduled = true
            return wait
        }
        guard let delay else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.controlled {
                self.keyFrameScheduled = false
                self.lastForcedKeyFrame = ProcessInfo.processInfo.systemUptime
            }
            self.sendKeyFrame()
        }
    }

    /// Новому зрителю нужен ключевой кадр. Если экран не меняется, ReplayKit новых кадров не шлёт,
    /// поэтому заново сжимаем последний полученный.
    private func sendKeyFrame() {
        lock.lock()
        defer { lock.unlock() }
        guard let sample = latestSample, let video = processor.videoFrame(sample) else { return }
        h264.encode(video.buffer, time: CMSampleBufferGetPresentationTimeStamp(sample),
                    quarterTurns: video.quarterTurns, forceKeyFrame: true)
    }

    private func congestion() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let bitrate = controlled({ quality.lowerOnCongestion(now: now) }) else { return }
        h264.setBitrate(bitrate)
        server?.log("Wi-Fi не успевает, битрейт \(bitrate / 1_000_000) Мбит/с")
    }

    private func viewerStats(_ stats: StreamServer.ViewerStats) {
        guard let fps = controlled({ quality.adaptFrameRate(to: stats) }) else { return }
        h264.setFrameRate(Int(fps))
        server?.log("телевизор показывает \(stats.shownFps) из \(stats.receivedFps) к/с, частота снижена до \(Int(fps))")
    }

    private func controlled<T>(_ body: () -> T) -> T {
        controlLock.lock()
        defer { controlLock.unlock() }
        return body()
    }

    private func finish(_ message: String) {
        finishBroadcastWithError(NSError(domain: "ScreenShare", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: message]))
    }
}

/// Подстройка качества под Wi-Fi и телевизор.
///
/// - Затор в сети (очередь зрителя переполнилась) — битрейт ×0,7, но не ниже 3 Мбит/с.
///   Если 15 секунд заторов нет, раз в 10 секунд битрейт растёт ×1,2 до 12 Мбит/с.
/// - Телевизор трижды подряд показал меньше 80 % принятых кадров — декодер не успевает,
///   частота снижается с 60 до 30 к/с до конца вещания.
struct QualityControl {
    static let maxFps: Double = 60
    static let maxBitrate = 12_000_000
    static let minBitrate = 3_000_000

    private(set) var bitrate = QualityControl.maxBitrate
    private(set) var fps = QualityControl.maxFps
    private var lastCongestion: TimeInterval = -100
    private var lastRaise: TimeInterval = -100
    private var slowDecoderReports = 0

    mutating func lowerOnCongestion(now: TimeInterval) -> Int? {
        lastCongestion = now
        let lowered = max(Self.minBitrate, bitrate * 7 / 10)
        guard lowered != bitrate else { return nil }
        bitrate = lowered
        return bitrate
    }

    mutating func raiseIfCalm(now: TimeInterval) -> Int? {
        guard bitrate < Self.maxBitrate, now - lastCongestion > 15, now - lastRaise > 10 else { return nil }
        lastRaise = now
        bitrate = min(Self.maxBitrate, bitrate * 6 / 5)
        return bitrate
    }

    mutating func adaptFrameRate(to stats: StreamServer.ViewerStats) -> Double? {
        guard fps > 30 else { return nil }
        let slow = stats.receivedFps >= 20 && Double(stats.shownFps) < Double(stats.receivedFps) * 0.8
        slowDecoderReports = slow ? slowDecoderReports + 1 : 0
        guard slowDecoderReports >= 3 else { return nil }
        fps = 30
        return fps
    }
}

/// Пропускает не больше `fps` кадров в секунду.
///
/// Кадры ReplayKit приходят неровно, с дрожанием в пару миллисекунд. Строгая проверка
/// «прошло не меньше 1/fps» отбрасывает кадр, пришедший чуть раньше срока, и ждёт следующего:
/// так из 30 кадров в секунду получалось около 20. Поэтому допускаем кадр на четверть интервала раньше.
struct FrameLimiter {
    private let interval: TimeInterval
    private var last: TimeInterval = 0

    init(fps: Double) {
        interval = 1 / fps
    }

    mutating func allow(_ now: TimeInterval) -> Bool {
        guard now - last >= interval * 0.75 else { return false }
        last = now
        return true
    }
}
