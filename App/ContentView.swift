import Network
import ReplayKit
import SwiftUI

struct ContentView: View {
    @State private var address = LocalNetwork.wifiAddress()
    @State private var picker = BroadcastPicker()
    @StateObject private var monitor = BroadcastMonitor()
    // Поиск в Bonjour при первом запуске вызывает системный запрос доступа к локальной сети.
    // Без этого доступа телефоны не найдут друг друга.
    @State private var browser: NWBrowser?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Экран на ТВ")
                    .font(.largeTitle.bold())

                step(1, "Подключи телефон и телевизор к одной сети Wi-Fi.")

                VStack(alignment: .leading, spacing: 12) {
                    step(2, "Нажми кнопку и подтверди «Начать вещание» в окне iOS.")
                    broadcastButton
                    if monitor.isLive {
                        Label("Вещание идёт", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    step(3, "Открой в браузере телевизора адрес:")
                    if let address {
                        Text(verbatim: "http://\(address):\(LocalNetwork.port)")
                            .font(.system(.title2, design: .monospaced).bold())
                            .textSelection(.enabled)
                    } else {
                        Text("Wi-Fi не подключён")
                            .foregroundStyle(.red)
                    }
                }

                Text("Второй телефон: установи на него это приложение и тоже начни вещание. Адрес вводить не нужно: его экран сам появится на телевизоре рядом с первым.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onAppear {
            requestLocalNetworkAccess()
            monitor.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            address = LocalNetwork.wifiAddress()
        }
    }

    private var broadcastButton: some View {
        Button(action: picker.show) {
            Label(monitor.isLive ? "Остановить вещание" : "Начать вещание",
                  systemImage: monitor.isLive ? "stop.circle.fill" : "record.circle")
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
        .tint(monitor.isLive ? Color.red : Color.accentColor)
        // Системная кнопка должна быть в иерархии окон, иначе она не откроет выбор трансляции.
        .background(PickerHost(picker: picker).frame(width: 1, height: 1).opacity(0.01))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
                .foregroundStyle(.white)
            Text(text)
        }
    }

    private func requestLocalNetworkAccess() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: LocalNetwork.serviceType, domain: nil), using: .tcp)
        browser.start(queue: .main)
        self.browser = browser
    }
}

/// Системная кнопка трансляции маленькая и почти не видна на тёмном фоне.
/// Поэтому она спрятана, а нажатие ей передаёт наша большая кнопка.
final class BroadcastPicker {
    let view: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        // Идентификатор берём из бандла: Sideloadly может поменять его при подписи.
        picker.preferredExtension = Bundle.main.bundleIdentifier.map { $0 + ".broadcast" }
        picker.showsMicrophoneButton = false
        return picker
    }()

    func show() {
        for case let button as UIButton in view.subviews {
            button.sendActions(for: .allTouchEvents)
        }
    }
}

struct PickerHost: UIViewRepresentable {
    let picker: BroadcastPicker

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        picker.view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Узнаёт, идёт ли вещание: пока оно идёт, расширение слушает порт на этом же телефоне.
final class BroadcastMonitor: ObservableObject {
    @Published private(set) var isLive = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.probe()
        }
        probe()
    }

    private func probe() {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: LocalNetwork.port)!,
                                      using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.update(true)
                connection.cancel()
            case .waiting, .failed:
                self?.update(false)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func update(_ live: Bool) {
        if isLive != live { isLive = live }
    }
}
