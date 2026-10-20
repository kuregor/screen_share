import Foundation

enum LocalNetwork {
    static let port: UInt16 = 8080
    static let videoPort: UInt16 = 8081
    static let serviceType = "_screenshare._tcp"

    /// IPv4-адрес телефона в сети Wi-Fi (интерфейс en0) или nil, если Wi-Fi не подключён.
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = item.pointee
            guard let addr = iface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: iface.ifa_name) == "en0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
