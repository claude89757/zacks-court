import Foundation
import CryptoKit
import Security

/// Browser display credentials (docs/web-display.md §4). The token travels only in the QR code's
/// URL fragment and as an HMAC key; the 6-digit PIN is for typing the address by hand.
public struct WebDisplayCredentials: Codable, Equatable, Sendable {
    public var token: String
    public var pin: String
    public var expires: Date
    public static let lifetime: TimeInterval = 12 * 3600

    public init(token: String, pin: String, expires: Date) { self.token = token; self.pin = pin; self.expires = expires }

    public static func make(now: Date = Date()) -> WebDisplayCredentials {
        WebDisplayCredentials(token: base64URL(random(32)), pin: makePIN(), expires: now.addingTimeInterval(lifetime))
    }
    public func withNewPIN() -> WebDisplayCredentials {
        var copy = self
        repeat { copy.pin = Self.makePIN() } while copy.pin == pin
        return copy
    }
    public func isValid(at date: Date = Date()) -> Bool { expires > date && token.count >= 32 && pin.count == 6 }

    static func makePIN() -> String {
        // Rejection sampling keeps the six digits uniform.
        while true {
            let bytes = random(4)
            let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if value < 4_294_000_000 { return String(format: "%06u", value % 1_000_000) }
        }
    }
    static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes
    }
    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// HMAC-SHA256(key: token UTF-8, message: nonce UTF-8) in lowercase hex, as the page computes it.
    public func mac(nonce: String) -> String {
        Self.hex(HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: SymmetricKey(data: Data(token.utf8))))
    }
}

/// Keeps the browser display credentials in the keychain (not UserDefaults), so browsers can
/// reconnect after the app restarts until the token expires.
public enum WebDisplayKeychain {
    static let service = "com.zackscourt.web-display"
    static let account = "credentials"
    public static func load() -> WebDisplayCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let value = try? JSONDecoder().decode(WebDisplayCredentials.self, from: data), value.isValid() else { return nil }
        return value
    }
    public static func save(_ value: WebDisplayCredentials) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
        }
    }
    public static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

/// JSON for browsers: the v2 message bodies inside `{kind, t, body}`, with dates as milliseconds
/// since 1970 so `new Date(n)` works. The native link keeps Foundation's default encoding.
public enum WebWire {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.userInfo[.courtDisplayText] = true
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder
    }
    struct Envelope<Body: Encodable>: Encodable {
        let kind: String
        let t: Double
        let body: Body
    }
    struct Kind: Decodable { let kind: String }
    struct Incoming<Body: Decodable>: Decodable { let body: Body }

    public static func envelope<Body: Encodable>(_ kind: String, _ body: Body) throws -> Data {
        try encoder.encode(Envelope(kind: kind, t: (Date().timeIntervalSince1970 * 1000).rounded(), body: body))
    }
    public static func kind(of data: Data) -> String? { try? JSONDecoder().decode(Kind.self, from: data).kind }
    public static func body<Body: Decodable>(_ type: Body.Type, from data: Data) throws -> Body {
        try decoder.decode(Incoming<Body>.self, from: data).body
    }

    /// Binary frame: 1 byte type, 4-byte big-endian JSON length, JSON, then the JPEG bytes.
    public enum BinaryType: UInt8 { case preview = 1, still = 2 }
    public struct ImageInfo: Codable, Sendable {
        public var width: Int
        public var height: Int
        public var streamID: UUID?
        /// Still: the `WireControl.id` of the request.
        public var request: UUID?
        public init(width: Int, height: Int, streamID: UUID? = nil, request: UUID? = nil) {
            self.width = width; self.height = height; self.streamID = streamID; self.request = request
        }
    }
    public static func binary(_ type: BinaryType, info: ImageInfo, jpeg: Data) throws -> Data {
        let json = try encoder.encode(info)
        var data = Data([type.rawValue])
        var length = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json); data.append(jpeg)
        return data
    }
}

/// Auth messages exchanged on the browser WebSocket before anything else.
public struct WebAuthChallenge: Codable, Sendable {
    public var nonce: String
    public var version = WireProtocol.version
    public var camera: String
}
public struct WebAuthRequest: Codable, Sendable {
    public var mac: String?
    public var pin: String?
}
public struct WebAuthResult: Codable, Sendable {
    public var ok: Bool
    public var message: String?
    /// Only after a correct PIN, so the page can reconnect without it.
    public var token: String?
    /// Per-connection key for `/api/*` requests (`?k=`).
    public var access: String?
}
public struct WebPreviewRequest: Codable, Sendable { public var enabled: Bool }

// MARK: - HTTP and WebSocket framing

public struct WebHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Lowercased header names.
    public var headers: [String: String]
    public static let maximumHeader = 16 << 10

    /// Parses a request head from `data`; nil while the blank line has not arrived yet.
    public static func parse(_ data: Data) throws -> (request: WebHTTPRequest, length: Int)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maximumHeader { throw CourtError.message("请求头过长。") }
            return nil
        }
        guard end.lowerBound <= maximumHeader, let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            throw CourtError.message("请求头无效。")
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw CourtError.message("请求行无效。") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        guard target.hasPrefix("/"), let components = URLComponents(string: target) else { throw CourtError.message("请求路径无效。") }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = WebHTTPRequest(method: String(parts[0]).uppercased(), path: components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath,
                                     query: query, headers: headers)
        return (request, data.distance(from: data.startIndex, to: end.upperBound))
    }

    /// Single `bytes=a-b`, `bytes=a-` or `bytes=-n` range within `size`; nil when absent or unusable.
    public func byteRange(size: Int64) -> ClosedRange<Int64>? {
        guard size > 0, let value = headers["range"], value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let spec = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty {
            guard let suffix = Int64(spec[1]), suffix > 0 else { return nil }
            return max(0, size - suffix)...(size - 1)
        }
        guard let start = Int64(spec[0]), start < size else { return nil }
        let end = spec[1].isEmpty ? size - 1 : min(size - 1, Int64(spec[1]) ?? -1)
        return end >= start ? start...end : nil
    }
}

public enum WebSocketOpcode: UInt8, Sendable { case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }

public enum WebSocketFrame {
    public static let maximumIncoming = 1 << 20

    public static func acceptKey(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// Unmasked server frame.
    public static func encode(_ opcode: WebSocketOpcode, _ payload: Data) -> Data {
        var data = Data([0x80 | opcode.rawValue])
        if payload.count < 126 { data.append(UInt8(payload.count)) }
        else if payload.count <= 0xFFFF {
            data.append(126); data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 0xFF))
        } else {
            data.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        data.append(payload)
        return data
    }

    /// Client frames must be masked and unfragmented (browsers do not fragment these messages).
    public struct Decoder {
        private var pending = Data()
        public init() {}
        public mutating func append(_ chunk: Data) throws -> [(WebSocketOpcode, Data)] {
            pending.append(chunk)
            guard pending.count <= maximumIncoming + 16 else { throw CourtError.message("WebSocket 消息过大。") }
            var frames: [(WebSocketOpcode, Data)] = []
            var bytes = [UInt8](pending)
            var offset = 0
            while bytes.count - offset >= 2 {
                let first = bytes[offset], second = bytes[offset + 1]
                guard first & 0x70 == 0 else { throw CourtError.message("WebSocket 帧无效。") }
                guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else { throw CourtError.message("不支持的 WebSocket 帧。") }
                guard first & 0x80 != 0, opcode != .continuation else { throw CourtError.message("不支持分片的 WebSocket 消息。") }
                guard second & 0x80 != 0 else { throw CourtError.message("浏览器发来的 WebSocket 帧必须加掩码。") }
                var length = Int(second & 0x7F), cursor = offset + 2
                if length == 126 {
                    guard bytes.count - cursor >= 2 else { break }
                    length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]); cursor += 2
                } else if length == 127 {
                    guard bytes.count - cursor >= 8 else { break }
                    var value: UInt64 = 0
                    for index in 0..<8 { value = value << 8 | UInt64(bytes[cursor + index]) }
                    guard value <= UInt64(maximumIncoming) else { throw CourtError.message("WebSocket 消息过大。") }
                    length = Int(value); cursor += 8
                }
                guard length <= maximumIncoming else { throw CourtError.message("WebSocket 消息过大。") }
                guard bytes.count - cursor >= 4 + length else { break }
                let mask = Array(bytes[cursor..<(cursor + 4)]); cursor += 4
                for index in 0..<length { bytes[cursor + index] ^= mask[index & 3] }
                frames.append((opcode, Data(bytes[cursor..<(cursor + length)])))
                offset = cursor + length
            }
            pending = Data(bytes[offset...])
            return frames
        }
    }
}

/// What the camera answers to an authenticated `/api/*` request.
public enum WebHTTPResponse: Sendable {
    case json(Data)
    case error(Int, String)
    /// Streams a file with Range support. `onFinish` runs once when the response ends.
    case file(URL, contentType: String, downloadName: String?, onFinish: (@Sendable () -> Void)?)
}

/// Locates the bundled page. Not `Bundle.module`: that traps when the resource bundle is missing.
public enum WebDisplayResources {
    public static let bundleName = "ZacksCourt_CourtCore.bundle"
    public static var directory: URL? {
        if let path = ProcessInfo.processInfo.environment["COURT_WEB_ROOT"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) ? url : nil
        }
        var candidates: [URL] = []
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle(for: Marker.self).resourceURL,
                     Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()].compactMap({ $0 }) {
            candidates.append(base.appendingPathComponent(bundleName))
            candidates.append(base.appendingPathComponent(bundleName).appendingPathComponent("Contents/Resources"))
        }
        for bundle in candidates {
            let web = bundle.appendingPathComponent("Web", isDirectory: true)
            if FileManager.default.fileExists(atPath: web.appendingPathComponent("index.html").path) { return web }
        }
        return nil
    }
    private final class Marker {}
}
