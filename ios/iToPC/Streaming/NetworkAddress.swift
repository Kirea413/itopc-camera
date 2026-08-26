import Darwin
import Foundation

enum NetworkAddress {
    static var wifiIPv4: String {
        var address = "未接続"
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return address }
        defer { freeifaddrs(interfaces) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                address = String(cString: host)
                break
            }
        }
        return address
    }
}
