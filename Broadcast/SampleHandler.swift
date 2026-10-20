import ReplayKit

/// Точка входа расширения: ReplayKit отдаёт сюда кадры экрана, пока идёт вещание.
final class SampleHandler: RPBroadcastSampleHandler {
    private let encoder = FrameEncoder()
    private var server: StreamServer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let address = LocalNetwork.wifiAddress() else {
            finish("Подключи телефон к Wi-Fi и начни вещание снова.")
            return
        }
        let server = StreamServer(address: address)
        server.onFailure = { [weak self] error in
            self?.finish("Не удалось открыть порт \(LocalNetwork.port): \(error.localizedDescription)")
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
        // Кадры сжимаем, только когда телевизор подключён: так расширение не тратит батарею впустую.
        guard sampleBufferType == .video, let server, server.hasViewers,
              let jpeg = encoder.encode(sampleBuffer) else { return }
        server.broadcast(jpeg)
    }

    private func finish(_ message: String) {
        finishBroadcastWithError(NSError(domain: "ScreenShare", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
