import Network
import ReplayKit
import SwiftUI

struct ContentView: View {
    @State private var address = LocalNetwork.wifiAddress()
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
                    step(2, "Нажми кнопку и выбери «Начать вещание».")
                    BroadcastButton()
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        .frame(maxWidth: .infinity)
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
        .onAppear(perform: requestLocalNetworkAccess)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            address = LocalNetwork.wifiAddress()
        }
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

/// Системная кнопка запуска трансляции, сразу настроенная на наше расширение.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        // Идентификатор берём из бандла: Sideloadly может поменять его при подписи.
        picker.preferredExtension = Bundle.main.bundleIdentifier.map { $0 + ".broadcast" }
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
