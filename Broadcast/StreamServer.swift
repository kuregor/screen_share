import Foundation
import Network

/// HTTP-сервер внутри телефона. Телевизор открывает его в браузере.
///
/// Маршруты:
/// - `/` — страница для телевизора (tv.html);
/// - `/stream` — экран телефона потоком MJPEG;
/// - `/status` — JSON с адресами других телефонов, найденных через Bonjour.
///   По нему страница сама подключает второй телефон.
final class StreamServer {
    var onFailure: ((Error) -> Void)?

    private let ownHost: String
    private let queue = DispatchQueue(label: "StreamServer")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var viewers: [Viewer] = []
    private var peers: [String] = []
    private var lastFrame: Data?

    private let lock = NSLock()
    private var viewerCount = 0

    private lazy var page: Data = {
        Bundle(for: StreamServer.self).url(forResource: "tv", withExtension: "html")
            .flatMap { try? Data(contentsOf: $0) } ?? Data("tv.html не найден".utf8)
    }()

    /// Читается из потока ReplayKit, поэтому под замком.
    var hasViewers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return viewerCount > 0
    }

    init(address: String) {
        ownHost = "\(address):\(LocalNetwork.port)"
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: LocalNetwork.port)!)
        // Адрес кладём в TXT-запись, чтобы соседям не пришлось резолвить имя сервиса.
        listener.service = NWListener.Service(name: "iPhone \(ownHost)", type: LocalNetwork.serviceType,
                                              domain: nil, txtRecord: NWTXTRecord(["host": ownHost]))
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onFailure?(error) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener

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
            self.browser?.cancel()
            self.viewers.forEach { $0.connection.cancel() }
            self.viewers.removeAll()
            self.updateViewerCount()
        }
    }

    func broadcast(_ jpeg: Data) {
        queue.async {
            self.lastFrame = jpeg
            self.viewers.forEach { self.send(jpeg, to: $0) }
        }
    }

    // MARK: - Соединения

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
        case "/status":
            let status: [String: Any] = ["host": ownHost, "peers": peers]
            let body = (try? JSONSerialization.data(withJSONObject: status)) ?? Data()
            respond(connection, type: "application/json", body: body)
        case "/stream":
            startStream(connection)
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
        viewers.removeAll { $0.connection === connection }
        updateViewerCount()
    }

    private func updatePeers(_ results: Set<NWBrowser.Result>) {
        peers = results.compactMap { result -> String? in
            guard case .bonjour(let txt) = result.metadata, let host = txt["host"], host != ownHost else {
                return nil
            }
            return host
        }.sorted()
    }

    // MARK: - Поток MJPEG

    private final class Viewer {
        let connection: NWConnection
        var sending = false
        var pending: Data?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private func startStream(_ connection: NWConnection) {
        // Разделитель ставим сразу после каждого кадра: так Chrome показывает кадр,
        // не дожидаясь начала следующего.
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
            + "--frame\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        let viewer = Viewer(connection: connection)
        viewers.append(viewer)
        updateViewerCount()
        // Если экран телефона не меняется, новых кадров нет. Отдаём последний, чтобы не было чёрного экрана.
        if let lastFrame { send(lastFrame, to: viewer) }
    }

    /// Пока предыдущий кадр не ушёл, новый не шлём, а запоминаем последний.
    /// Так медленный Wi-Fi не копит задержку: телевизор всегда получает свежий кадр.
    private func send(_ jpeg: Data, to viewer: Viewer) {
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

    private func updateViewerCount() {
        lock.lock()
        viewerCount = viewers.count
        lock.unlock()
    }
}
