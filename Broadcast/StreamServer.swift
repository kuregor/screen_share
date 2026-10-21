import Foundation
import Network

/// Сервер внутри телефона. Телевизор открывает его в браузере.
///
/// HTTP на порту `LocalNetwork.port`:
/// - `/` — страница для телевизора (tv.html), `/jmuxer.min.js` — библиотека для неё;
/// - `/stream` — экран потоком MJPEG, запасной вариант для старых браузеров;
/// - `/status` — JSON с портами, токеном сокетов и адресами других телефонов, найденных через Bonjour.
///   По нему страница сама подключает второй телефон;
/// - `/msx/start.json`, `/msx/content.json` — запуск через приложение Media Station X на телевизоре;
/// - `/log` — журнал диагностики: пишут страница телевизора и само расширение.
///
/// WebSocket на порту `LocalNetwork.videoPort` — экран в H.264. Каждое сообщение:
/// 1 байт флагов (бит 0 — ключевой кадр, биты 1–2 — сколько четвертей оборота по часовой
/// повернуть кадр при показе), 4 байта времени кадра в мс (big-endian), затем кадр в Annex B.
/// Страница шлёт обратно текстом свои цифры: {"fps": показано, "rx": принято, "lag": отставание}.
/// Звук не передаётся.
///
/// Защита. Сокет принимает только подпротокол `t-<токен>`. Токен отдаёт `/status`, а прочитать
/// ответ `/status` из браузера можно только со страницы, загруженной с телефона в локальной сети
/// (CORS). Так чужой сайт, открытый на любом устройстве в этой же сети, не утащит экран телефона.
final class StreamServer {
    struct ViewerStats {
        let shownFps: Int
        let receivedFps: Int
        let lag: Double
    }

    var onFailure: ((Error) -> Void)?
    /// Новому зрителю H.264 нужен ключевой кадр, без него видео не начнётся.
    var onKeyFrameNeeded: (() -> Void)?
    /// Очередь зрителя переполнилась: Wi-Fi не успевает за битрейтом.
    var onCongestion: (() -> Void)?
    /// Цифры, которые прислала страница телевизора.
    var onViewerStats: ((ViewerStats) -> Void)?

    private let ownHost: String
    private let token: String
    private let queue = DispatchQueue(label: "StreamServer")
    private var listeners: [NWListener] = []
    private var browser: NWBrowser?
    private var jpegViewers: [JPEGViewer] = []
    private var videoViewers: [SocketViewer] = []
    private var peers: [String] = []
    private var lastJPEG: Data?
    private var logLines: [String] = []
    private let logStart = Date()

    private let lock = NSLock()
    private var jpegViewerCount = 0
    private var videoViewerCount = 0

    private lazy var page = Self.resource("tv", "html")
    private lazy var jmuxer = Self.resource("jmuxer.min", "js")

    // Читаются из потока ReplayKit, поэтому под замком.
    var hasJPEGViewers: Bool { counted { jpegViewerCount > 0 } }
    var hasVideoViewers: Bool { counted { videoViewerCount > 0 } }

    init(address: String) {
        ownHost = "\(address):\(LocalNetwork.port)"
        token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
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

        let videoListener = try makeSocketListener(port: LocalNetwork.videoPort) { [weak self] connection in
            self?.acceptSocket(connection)
        }

        listeners = [listener, videoListener]
        for item in listeners {
            item.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.onFailure?(error) }
            }
            item.start(queue: queue)
        }

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LocalNetwork.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updatePeers(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        queue.async {
            self.listeners.forEach { $0.cancel() }
            self.browser?.cancel()
            self.jpegViewers.forEach { $0.connection.cancel() }
            self.videoViewers.forEach { $0.connection.cancel() }
            self.jpegViewers.removeAll()
            self.videoViewers.removeAll()
            self.updateViewerCounts()
        }
    }

    /// Запись в журнал `/log` от самого расширения.
    func log(_ message: String) {
        queue.async { self.appendLog("телефон: " + message) }
    }

    func broadcast(_ jpeg: Data) {
        queue.async {
            self.lastJPEG = jpeg
            self.jpegViewers.forEach { self.send(jpeg, to: $0) }
        }
    }

    func broadcastVideo(_ frame: Data, isKey: Bool, timestamp: UInt32, quarterTurns: UInt8) {
        let flags = (isKey ? 1 : 0) | (quarterTurns & 3) << 1
        let packet = Self.packet(frame, flags: flags, timestamp: timestamp)
        queue.async {
            var congested = false
            for viewer in self.videoViewers {
                // P-кадр бесполезен без предыдущих, поэтому после пропуска ждём ключевой.
                if viewer.waitingForKey {
                    guard isKey else { continue }
                    viewer.waitingForKey = false
                }
                viewer.queue.append(packet)
                // Wi-Fi не успевает: выбрасываем очередь, чтобы не копить задержку, и ждём ключевой кадр.
                // 30 кадров — около полсекунды при 60 к/с.
                if viewer.queue.count > 30 {
                    viewer.queue.removeAll()
                    viewer.waitingForKey = true
                    congested = true
                }
                self.pump(viewer)
            }
            if congested {
                self.onCongestion?()
                self.onKeyFrameNeeded?()
            }
        }
    }

    private static func packet(_ payload: Data, flags: UInt8, timestamp: UInt32) -> Data {
        var packet = Data([flags])
        withUnsafeBytes(of: timestamp.bigEndian) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }

    private func counted(_ read: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return read()
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
        let lines = head.components(separatedBy: "\r\n")
        let target = lines[0].split(separator: " ", maxSplits: 2).dropFirst().first ?? ""
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first ?? ""
        let query = parts.count > 1 ? String(parts[1]) : ""
        let origin = lines.dropFirst().first { $0.lowercased().hasPrefix("origin:") }
            .map { $0.dropFirst("origin:".count).trimmingCharacters(in: .whitespaces) }

        switch path {
        case "/log":
            // Журнал диагностики: страница телевизора пишет сюда, что у неё происходит,
            // а с компьютера в той же сети его можно прочитать: http://адрес-телефона:8080/log
            if query.hasPrefix("m="), let message = String(query.dropFirst(2)).removingPercentEncoding {
                appendLog(message)
                respond(connection, type: "text/plain", body: Data("ok".utf8))
            } else {
                respond(connection, type: "text/plain; charset=utf-8", body: Data(logLines.joined(separator: "\n").utf8))
            }
        case "/":
            respond(connection, type: "text/html; charset=utf-8", body: page)
        case "/jmuxer.min.js":
            respond(connection, type: "application/javascript", body: jmuxer)
        case "/status":
            let status: [String: Any] = ["host": ownHost, "video": Int(LocalNetwork.videoPort),
                                         "token": token, "peers": peers]
            // В ответе токен, поэтому читать его разрешаем только страницам с телефонов в локальной сети.
            respond(connection, type: "application/json", body: Self.json(status),
                    allowOrigin: origin.flatMap { Self.isLocalPage($0) ? $0 : nil })
        case "/stream":
            startJPEGStream(connection)
        case "/msx/start.json":
            // Media Station X: «Стартовый параметр» = адрес телефона. {SERVER} приложение подставит само.
            // MSX загружает файл со своего сайта, поэтому CORS открыт; секретов здесь нет.
            let start = ["name": "Экран на ТВ", "version": "1.0.0",
                         "parameter": "content:http://{SERVER}/msx/content.json"]
            respond(connection, type: "application/json", body: Self.json(start), allowOrigin: "*")
        case "/msx/content.json":
            respond(connection, type: "application/json", body: Self.json(msxContent), allowOrigin: "*")
        default:
            respond(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }

    /// Страница, загруженная с телефона в локальной сети: http://<частный IPv4>:<порт сервера>.
    private static func isLocalPage(_ origin: String) -> Bool {
        guard let url = URL(string: origin), url.scheme == "http", url.port == Int(LocalNetwork.port),
              let host = url.host else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK", type: String, body: Data,
                         allowOrigin: String? = nil) {
        var head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
        if let allowOrigin {
            head += "Access-Control-Allow-Origin: \(allowOrigin)\r\nVary: Origin\r\n"
        }
        head += "\r\n"
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

    private func appendLog(_ message: String) {
        logLines.append(String(format: "%7.1f ", Date().timeIntervalSince(logStart)) + message)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
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

    // MARK: - Сокет видео

    private final class SocketViewer {
        let connection: NWConnection
        var queue: [Data] = []
        var sending = false
        var waitingForKey = true

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private func makeSocketListener(port: UInt16, accept: @escaping (NWConnection) -> Void) throws -> NWListener {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        // Пускаем только тех, кто знает токен из /status.
        let expected = "t-" + token
        options.setClientRequestHandler(queue) { subprotocols, _ in
            subprotocols.contains(expected)
                ? NWProtocolWebSocket.Response(status: .accept, subprotocol: expected)
                : NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = accept
        return listener
    }

    private func acceptSocket(_ connection: NWConnection) {
        let viewer = SocketViewer(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.videoViewers.append(viewer)
                self.updateViewerCounts()
                self.onKeyFrameNeeded?()
            case .failed, .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveMessages(connection)
    }

    /// Читаем входящие: так обрабатываются ping и закрытие сокета, а ещё страница
    /// присылает свои цифры (сколько кадров принято и показано).
    private func receiveMessages(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                connection.cancel()
                return
            }
            if metadata?.opcode == .text, let data,
               let stats = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self?.onViewerStats?(ViewerStats(shownFps: stats["fps"] as? Int ?? 0,
                                                 receivedFps: stats["rx"] as? Int ?? 0,
                                                 lag: stats["lag"] as? Double ?? 0))
            }
            self?.receiveMessages(connection)
        }
    }

    private func pump(_ viewer: SocketViewer) {
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
