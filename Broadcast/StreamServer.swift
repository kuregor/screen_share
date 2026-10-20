import Foundation
import Network

/// Сервер внутри телефона. Телевизор открывает его в браузере.
///
/// HTTP на порту `LocalNetwork.port`:
/// - `/` — страница для телевизора (tv.html), `/jmuxer.min.js` — библиотека для неё;
/// - `/stream` — экран потоком MJPEG, запасной вариант для старых браузеров;
/// - `/status` — JSON с адресами других телефонов, найденных через Bonjour.
///   По нему страница сама подключает второй телефон;
/// - `/msx/start.json`, `/msx/content.json` — запуск через приложение Media Station X на телевизоре.
///
/// WebSocket на порту `LocalNetwork.videoPort` — экран в H.264. Каждое сообщение:
/// 1 байт флагов (бит 0 — ключевой кадр), 4 байта времени кадра в мс (big-endian), затем кадр в Annex B.
final class StreamServer {
    var onFailure: ((Error) -> Void)?
    /// Новому зрителю H.264 нужен ключевой кадр, без него видео не начнётся.
    var onKeyFrameNeeded: (() -> Void)?

    private let ownHost: String
    private let queue = DispatchQueue(label: "StreamServer")
    private var listener: NWListener?
    private var videoListener: NWListener?
    private var browser: NWBrowser?
    private var jpegViewers: [JPEGViewer] = []
    private var videoViewers: [VideoViewer] = []
    private var peers: [String] = []
    private var lastJPEG: Data?

    private let lock = NSLock()
    private var jpegViewerCount = 0
    private var videoViewerCount = 0

    private lazy var page = Self.resource("tv", "html")
    private lazy var jmuxer = Self.resource("jmuxer.min", "js")

    // Читаются из потока ReplayKit, поэтому под замком.
    var hasJPEGViewers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return jpegViewerCount > 0
    }

    var hasVideoViewers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return videoViewerCount > 0
    }

    init(address: String) {
        ownHost = "\(address):\(LocalNetwork.port)"
    }

    func start() throws {
        let http = NWParameters.tcp
        http.allowLocalEndpointReuse = true
        let listener = try NWListener(using: http, on: NWEndpoint.Port(rawValue: LocalNetwork.port)!)
        // Адрес кладём в TXT-запись, чтобы соседям не пришлось резолвить имя сервиса.
        listener.service = NWListener.Service(name: "iPhone \(ownHost)", type: LocalNetwork.serviceType,
                                              domain: nil, txtRecord: NWTXTRecord(["host": ownHost]))
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        let ws = NWParameters.tcp
        ws.allowLocalEndpointReuse = true
        ws.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let videoListener = try NWListener(using: ws, on: NWEndpoint.Port(rawValue: LocalNetwork.videoPort)!)
        videoListener.newConnectionHandler = { [weak self] connection in
            self?.acceptVideo(connection)
        }

        for item in [listener, videoListener] {
            item.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.onFailure?(error) }
            }
            item.start(queue: queue)
        }
        self.listener = listener
        self.videoListener = videoListener

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LocalNetwork.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updatePeers(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.videoListener?.cancel()
            self.browser?.cancel()
            self.jpegViewers.forEach { $0.connection.cancel() }
            self.videoViewers.forEach { $0.connection.cancel() }
            self.jpegViewers.removeAll()
            self.videoViewers.removeAll()
            self.updateViewerCounts()
        }
    }

    func broadcast(_ jpeg: Data) {
        queue.async {
            self.lastJPEG = jpeg
            self.jpegViewers.forEach { self.send(jpeg, to: $0) }
        }
    }

    func broadcastVideo(_ frame: Data, isKey: Bool, timestamp: UInt32) {
        queue.async {
            var packet = Data([isKey ? 1 : 0])
            withUnsafeBytes(of: timestamp.bigEndian) { packet.append(contentsOf: $0) }
            packet.append(frame)

            var needsKeyFrame = false
            for viewer in self.videoViewers {
                // P-кадр бесполезен без предыдущих, поэтому после пропуска ждём ключевой.
                if viewer.waitingForKey {
                    guard isKey else { continue }
                    viewer.waitingForKey = false
                }
                viewer.queue.append(packet)
                // Wi-Fi не успевает: выбрасываем очередь, чтобы не копить задержку, и просим ключевой кадр.
                // 30 кадров — около полсекунды при 60 к/с.
                if viewer.queue.count > 30 {
                    viewer.queue.removeAll()
                    viewer.waitingForKey = true
                    needsKeyFrame = true
                }
                self.pump(viewer)
            }
            if needsKeyFrame { self.onKeyFrameNeeded?() }
        }
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, received: Data())
    }

    private func readRequest(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var received = received
            if let data { received.append(data) }

            if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                self.route(String(decoding: received[..<end.lowerBound], as: UTF8.self), connection)
            } else if error != nil || isComplete || received.count > 16_384 {
                connection.cancel()
            } else {
                self.readRequest(connection, received: received)
            }
        }
    }

    private func route(_ head: String, _ connection: NWConnection) {
        // Первая строка запроса: "GET /stream?t=123 HTTP/1.1".
        let target = head.split(separator: " ", maxSplits: 2).dropFirst().first ?? ""
        let path = target.split(separator: "?", omittingEmptySubsequences: false).first ?? ""

        switch path {
        case "/":
            respond(connection, type: "text/html; charset=utf-8", body: page)
        case "/jmuxer.min.js":
            respond(connection, type: "application/javascript", body: jmuxer)
        case "/status":
            let status: [String: Any] = ["host": ownHost, "video": Int(LocalNetwork.videoPort), "peers": peers]
            respond(connection, type: "application/json", body: Self.json(status))
        case "/stream":
            startJPEGStream(connection)
        case "/msx/start.json":
            // Media Station X: «Стартовый параметр» = адрес телефона. {SERVER} приложение подставит само.
            let start = ["name": "Экран на ТВ", "version": "1.0.0",
                         "parameter": "content:http://{SERVER}/msx/content.json"]
            respond(connection, type: "application/json", body: Self.json(start))
        case "/msx/content.json":
            respond(connection, type: "application/json", body: Self.json(msxContent))
        default:
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK", type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func drop(_ connection: NWConnection) {
        jpegViewers.removeAll { $0.connection === connection }
        videoViewers.removeAll { $0.connection === connection }
        updateViewerCounts()
    }

    private func updatePeers(_ results: Set<NWBrowser.Result>) {
        peers = results.compactMap { result -> String? in
            guard case .bonjour(let txt) = result.metadata, let host = txt["host"], host != ownHost else {
                return nil
            }
            return host
        }.sorted()
    }

    private func updateViewerCounts() {
        lock.lock()
        jpegViewerCount = jpegViewers.count
        videoViewerCount = videoViewers.count
        lock.unlock()
    }

    /// Страница MSX: при запуске сразу открывает экран телефона как видеоплагин,
    /// а после выхода по кнопке «Назад» показывает кнопку, чтобы открыть его снова.
    private var msxContent: [String: Any] {
        let plugin = "video:plugin:http://\(ownHost)/?msx"
        let button: [String: Any] = ["type": "button", "layout": "0,0,6,2", "icon": "cast",
                                     "label": "Показать экран телефона", "action": plugin]
        let hint: [String: Any] = ["type": "space", "layout": "0,2,12,2",
                                   "text": ["Начни вещание на iPhone и нажми кнопку выше.",
                                            "Второй телефон с этим приложением появится на экране сам."]]
        return ["headline": "Экран на ТВ", "action": plugin, "type": "pages",
                "pages": [["items": [button, hint]]]]
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func resource(_ name: String, _ ext: String) -> Data {
        Bundle(for: StreamServer.self).url(forResource: name, withExtension: ext)
            .flatMap { try? Data(contentsOf: $0) } ?? Data("\(name).\(ext) не найден".utf8)
    }

    // MARK: - Поток MJPEG

    private final class JPEGViewer {
        let connection: NWConnection
        var sending = false
        var pending: Data?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private func startJPEGStream(_ connection: NWConnection) {
        // Разделитель ставим сразу после каждого кадра: так Chrome показывает кадр,
        // не дожидаясь начала следующего.
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
            + "--frame\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let viewer = JPEGViewer(connection: connection)
        jpegViewers.append(viewer)
        updateViewerCounts()
        // Если экран телефона не меняется, новых кадров нет. Отдаём последний, чтобы не было чёрного экрана.
        if let lastJPEG { send(lastJPEG, to: viewer) }
    }

    /// Пока предыдущий кадр не ушёл, новый не шлём, а запоминаем последний.
    /// Так медленный Wi-Fi не копит задержку: телевизор всегда получает свежий кадр.
    private func send(_ jpeg: Data, to viewer: JPEGViewer) {
        guard !viewer.sending else {
            viewer.pending = jpeg
            return
        }
        viewer.sending = true
        let head = "Content-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n"
        let part = Data(head.utf8) + jpeg + Data("\r\n--frame\r\n".utf8)
        viewer.connection.send(content: part, completion: .contentProcessed { [weak self] error in
            viewer.sending = false
            if error != nil {
                viewer.connection.cancel()
            } else if let next = viewer.pending {
                viewer.pending = nil
                self?.send(next, to: viewer)
            }
        })
    }

    // MARK: - Поток H.264

    private final class VideoViewer {
        let connection: NWConnection
        var queue: [Data] = []
        var sending = false
        var waitingForKey = true

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private func acceptVideo(_ connection: NWConnection) {
        let viewer = VideoViewer(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self else { return }
                self.videoViewers.append(viewer)
                self.updateViewerCounts()
                self.onKeyFrameNeeded?()
            case .failed, .cancelled:
                self?.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveVideoMessages(connection)
    }

    /// Страница ничего не шлёт, но читать входящие нужно: так обрабатываются ping и закрытие сокета.
    private func receiveVideoMessages(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] _, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                connection.cancel()
            } else {
                self?.receiveVideoMessages(connection)
            }
        }
    }

    private func pump(_ viewer: VideoViewer) {
        guard !viewer.sending, !viewer.queue.isEmpty else { return }
        viewer.sending = true
        let packet = viewer.queue.removeFirst()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        viewer.connection.send(content: packet, contentContext: context, isComplete: true,
                               completion: .contentProcessed { [weak self] error in
            viewer.sending = false
            if error != nil {
                viewer.connection.cancel()
            } else {
                self?.pump(viewer)
            }
        })
    }
}
