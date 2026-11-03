import Foundation
import Network
import Security
import Darwin

public struct PairingTicket: Codable {
    public static let serviceType = "_zackscourt._tcp"
    public var version = 1
    public let service: String
    public let key: Data
    public let name: String
    public let expires: Date
    public var host: String?
    public var port: UInt16?
    /// The display also listens over Apple peer-to-peer Wi-Fi (Phase 3), so the camera can reach it
    /// without sharing a Wi-Fi network or hotspot. nil in tickets from earlier builds: off.
    public var peerToPeer: Bool?

    public init(name: String, peerToPeer: Bool = true) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CourtError.message("无法生成配对密钥。")
        }
        service = "court-" + UUID().uuidString.lowercased().prefix(8)
        key = Data(bytes); self.name = String(name.prefix(80))
        expires = Date().addingTimeInterval(12 * 3600)
        self.peerToPeer = peerToPeer
    }

    public func url() throws -> String {
        let token = try JSONEncoder().encode(self).base64EncodedString()
        var parts = URLComponents()
        parts.scheme = "zackscourt"; parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "ticket", value: token)]
        guard let url = parts.string else { throw CourtError.message("无法生成配对信息。") }
        return url
    }

    public static func parse(_ value: String) throws -> PairingTicket {
        guard value.utf8.count < 4096,
              let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "zackscourt", parts.host == "pair",
              let token = parts.queryItems?.first(where: { $0.name == "ticket" })?.value,
              let data = Data(base64Encoded: token) else { throw CourtError.message("这不是有效的球场配对码。") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, result.key.count == 32, result.expires > Date(),
              result.expires.timeIntervalSinceNow <= 13 * 3600,
              result.service.hasPrefix("court-"), result.service.count <= 40,
              result.name.count <= 80 else { throw CourtError.message("配对码无效或已过期，请在看板上刷新配对码后重新扫码。") }
        if let host = result.host {
            var address = in_addr()
            guard inet_pton(AF_INET, host, &address) == 1,
                  let port = result.port, port > 0 else { throw CourtError.message("配对地址无效。") }
        }
        return result
    }

    public func endpoint() -> NWEndpoint {
        if let host, let port, let nwPort = NWEndpoint.Port(rawValue: port) {
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        return .service(name: service, type: Self.serviceType, domain: "local.", interface: nil)
    }

    public func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(service.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A8)!)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // Peer-to-peer Wi-Fi (AWDL) lets the Bonjour service be found and reached with no shared
        // network. The address in the ticket still goes over the LAN or hotspot.
        parameters.includePeerToPeer = peerToPeer == true
        return parameters
    }
}

/// Which kind of interface a connection runs over, for the connection panels and device checks.
public enum LinkPath: String, Codable, Sendable {
    case peerToPeer, localNetwork, loopback, other
    public init(interface name: String?) {
        guard let name else { self = .other; return }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { self = .peerToPeer }
        else if name.hasPrefix("lo") { self = .loopback }
        else if name.hasPrefix("en") || name.hasPrefix("bridge") { self = .localNetwork }
        else { self = .other }
    }
    public var title: String {
        switch self {
        case .peerToPeer: return "点对点直连"
        case .localNetwork: return "局域网 / 热点"
        case .loopback: return "本机回环"
        case .other: return "其他网络"
        }
    }
}

public enum LocalNetwork {
    public static func ipv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var current = first; var output: [String] = []
        while let pointer = current {
            defer { current = pointer.pointee.ifa_next }
            let item = pointer.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  item.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let interface = String(cString: item.ifa_name)
            // Personal Hotspot / Internet Sharing can expose the listening address on a bridge.
            // Exclude cellular and VPN interfaces: pairing is explicitly local-network only.
            guard interface.hasPrefix("en") || interface.hasPrefix("bridge") else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: text)
                if !output.contains(address) { output.append(address) }
            }
        }
        return output
    }
}
