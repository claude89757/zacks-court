import Foundation
import Network

/// Camera-side HTTP + WebSocket server for browser displays (docs/web-display.md §3–§7).
///
/// Browsers cannot listen or speak TLS-PSK, so for them the camera listens. Plain HTTP/1.1 with
/// `Connection: close`, RFC 6455 WebSocket on `/ws`, static files from the bundled page, and
/// authenticated `/api/*` requests answered by `onHTTP`. All state lives on `queue`; callbacks
/// run there too.
public final class WebDisplayServer: @unchecked Sendable {
    public static let preferredPort: UInt16 = 8787
    /// A browser whose send backlog grows past this is disconnected; it gets a full resync on return.
    public static let controlBacklogLimit = 8 << 20
    /// Preview frames are skipped for a browser whose backlog is at least this (same as native).
    public static let previewBacklogLimit = CourtConnection.previewBacklogLimit
    public static let fileChunk = ClipExport.chunkSize
    public static let fileBacklog = ClipExport.backlogLimit
    public static let maxPINFailures = 5
    /// An access key keeps working this long after its WebSocket closes (a video may still be loading).
    public static let accessGrace: TimeInterval = 60

    public let queue = DispatchQueue(label: "court.web", qos: .userInitiated)
    public var onListening: ((UInt16) -> Void)?
    public var onFailure: ((String) -> Void)?
    /// A browser authenticated; it sends `hello` next.
    public var onJoined: ((UUID) -> Void)?
    /// Authenticated text message other than auth/preview: client, kind, the raw envelope.
    public var onMessage: ((UUID, String, Data) -> Void)?
    public var onLeft: ((UUID) -> Void)?
    /// Whether any browser has the preview open.
    public var onPreviewDemand: ((Bool) -> Void)?
    /// The PIN changed after too many wrong guesses.
    public var onCredentials: ((WebDisplayCredentials) -> Void)?
    public var onHTTP: ((WebHTTPRequest) async -> WebHTTPResponse)?

    public let webRoot: URL?
    private let cameraName: String
    private var credentials: WebDisplayCredentials
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var accessKeys: [String: (client: UUID, closedAt: Date?)] = [:]
    private var pinFailures = 0
    private var previewDemand = false
    private var heartbeat: DispatchSourceTimer?
    private let lock = NSLock()
    private var _clients = 0
    public var clientCount: Int { lock.lock(); defer { lock.unlock() }; return _clients }

    public init(credentials: WebDisplayCredentials, cameraName: String, webRoot: URL?) {
        self.credentials = credentials; self.cameraName = String(cameraName.prefix(80)); self.webRoot = webRoot
    }

    // MARK: Lifecycle

    /// Listens on `port` if free, otherwise on any port.
    public func start(port: UInt16? = WebDisplayServer.preferredPort) {
        queue.async { [self] in
            stopInternal()
            do { try listen(port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any) }
            catch { onFailure?(error.localizedDescription) }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.beat() }
            timer.resume(); heartbeat = timer
        }
    }
    public func stop(completion: (() -> Void)? = nil) { queue.async { [self] in stopInternal(); completion?() } }

    private func listen(_ port: NWEndpoint.Port) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let listener = try NWListener(using: parameters, on: port)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready: self.onListening?(listener.port?.rawValue ?? 0)
            case .failed(let error):
                self.listener = nil; listener.cancel()
                if port != .any { do { try self.listen(.any) } catch { self.onFailure?(error.localizedDescription) } }
                else { self.onFailure?(error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func stopInternal() {
        heartbeat?.cancel(); heartbeat = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        for peer in Array(peers.values) { peer.close() }
        peers = [:]; accessKeys = [:]
        setDemand()
        updateCount()
    }

    /// New credentials: a changed token disconnects every browser; a changed PIN only affects new logins.
    public func update(credentials: WebDisplayCredentials) {
        queue.async { [self] in
            let tokenChanged = credentials.token != self.credentials.token
            self.credentials = credentials; pinFailures = 0
            if tokenChanged {
                for peer in Array(peers.values) where peer.authenticated { peer.close() }
                accessKeys = [:]
            }
        }
    }

    // MARK: Sending

    public func broadcast(_ text: Data) { queue.async { [self] in for peer in peers.values where peer.authenticated { peer.sendText(text) } } }
    public func send(_ text: Data, to client: UUID) { queue.async { [self] in peer(client)?.sendText(text) } }
    public func sendBinary(_ data: Data, to client: UUID) { queue.async { [self] in peer(client)?.sendBinary(data) } }
    /// Best effort: only browsers with the preview open and a small backlog get the frame.
    public func broadcastPreview(_ data: Data) {
        queue.async { [self] in
            for peer in peers.values where peer.authenticated && peer.previewEnabled && peer.pendingBytes < Self.previewBacklogLimit {
                peer.sendBinary(data)
            }
        }
    }
    public func disconnect(_ client: UUID) { queue.async { [self] in peer(client)?.close() } }

    private func peer(_ id: UUID) -> Peer? { peers.values.first { $0.id == id && $0.authenticated } }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard peers.count < 32 else { connection.cancel(); return }
        let peer = Peer(connection: connection, server: self)
        peers[ObjectIdentifier(peer)] = peer
        peer.start()
    }

    fileprivate func closed(_ peer: Peer) {
        guard peers.removeValue(forKey: ObjectIdentifier(peer)) != nil else { return }
        if peer.authenticated {
            for (key, value) in accessKeys where value.client == peer.id { accessKeys[key] = (peer.id, Date()) }
            onLeft?(peer.id)
            setDemand(); updateCount()
        }
    }

    private func beat() {
        let now = Date()
        accessKeys = accessKeys.filter { $0.value.closedAt.map { now.timeIntervalSince($0) < Self.accessGrace } ?? true }
        for peer in Array(peers.values) { peer.beat(now) }
    }

    private func setDemand() {
        let demand = peers.values.contains { $0.authenticated && $0.previewEnabled }
        guard demand != previewDemand else { return }
        previewDemand = demand; onPreviewDemand?(demand)
    }
    private func updateCount() {
        let count = peers.values.filter(\.authenticated).count
        lock.lock(); _clients = count; lock.unlock()
    }

    // MARK: Requests

    fileprivate func route(_ request: WebHTTPRequest, peer: Peer) {
        guard request.method == "GET" || request.method == "HEAD" else { peer.respond(405, courtText("只支持 GET。")); return }
        if request.path == "/ws" {
            guard request.headers["upgrade"]?.lowercased() == "websocket", let key = request.headers["sec-websocket-key"],
                  request.headers["sec-websocket-version"] == "13" else { peer.respond(400, courtText("需要 WebSocket 升级。")); return }
            peer.upgrade(key: key, nonce: WebDisplayCredentials.hex(WebDisplayCredentials.random(16)))
            return
        }
        if request.path.hasPrefix("/api/") {
            let now = Date()
            guard let key = request.query["k"], let entry = accessKeys[key],
                  entry.closedAt.map({ now.timeIntervalSince($0) < Self.accessGrace }) ?? true else {
                peer.respond(401, courtText("访问码无效或已过期，请刷新浏览器看板。")); return
            }
            guard let handler = onHTTP else { peer.respond(503, courtText("机位暂不可用。")); return }
            Task { [weak self] in
                let response = await handler(request)
                self?.queue.async { peer.serve(response, request: request) }
            }
            return
        }
        serveStatic(request, peer: peer)
    }

    private func serveStatic(_ request: WebHTTPRequest, peer: Peer) {
        guard let webRoot else { peer.respond(503, courtText("浏览器看板资源缺失，请重新安装 App。")); return }
        let name = request.path == "/" ? "index.html" : String(request.path.dropFirst())
        guard !name.isEmpty, !name.contains("/"), !name.contains(".."), !name.hasPrefix("."),
              let type = Self.contentTypes[(name as NSString).pathExtension.lowercased()] else { peer.respond(404, courtText("没有这个页面。")); return }
        let url = webRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { peer.respond(404, courtText("没有这个页面。")); return }
        peer.serve(.file(url, contentType: type, downloadName: nil, onFinish: nil), request: request)
    }

    static let contentTypes = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
                               "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "png": "image/png",
                               "json": "application/json", "ico": "image/x-icon", "mp4": "video/mp4",
                               "m4a": "audio/mp4"]

    fileprivate func authenticate(_ peer: Peer, _ request: WebAuthRequest) {
        guard credentials.isValid() else {
            peer.authFailed(courtText("浏览器看板配对已过期，请在机位上点「连接」刷新配对后重新扫码。"), close: true); return
        }
        var token: String?
        if let mac = request.mac {
            guard Self.constantTimeEqual(mac.lowercased(), credentials.mac(nonce: peer.nonce)) else {
                peer.authFailed(courtText("配对令牌无效或已过期，请重新扫描机位上的二维码。"), close: true); return
            }
        } else if let pin = request.pin {
            guard pinFailures < Self.maxPINFailures else { peer.authFailed(courtText("配对码已更换，请输入机位屏幕上的新配对码。"), close: false); return }
            guard Self.constantTimeEqual(pin, credentials.pin) else {
                pinFailures += 1
                if pinFailures >= Self.maxPINFailures {
                    credentials = credentials.withNewPIN(); pinFailures = 0
                    onCredentials?(credentials)
                    peer.authFailed(courtText("配对码错误次数过多，机位已换新码，请输入机位屏幕上的新配对码。"), close: false)
                } else {
                    peer.authFailed(courtFormat("配对码不正确（还可再试 %1$@ 次）。", "\(Self.maxPINFailures - pinFailures)"), close: false)
                }
                return
            }
            token = credentials.token
        } else { peer.authFailed(courtText("缺少配对信息。"), close: true); return }
        let access = WebDisplayCredentials.hex(WebDisplayCredentials.random(16))
        accessKeys[access] = (peer.id, nil)
        peer.authenticated = true
        peer.sendText((try? WebWire.envelope("auth", WebAuthResult(ok: true, token: token, access: access))) ?? Data())
        updateCount()
        onJoined?(peer.id)
    }

    fileprivate func received(_ text: Data, from peer: Peer) {
        guard let kind = WebWire.kind(of: text) else { peer.close(); return }
        if !peer.authenticated {
            guard kind == "auth", let request = try? WebWire.body(WebAuthRequest.self, from: text) else { peer.close(); return }
            authenticate(peer, request); return
        }
        switch kind {
        case "auth": break
        case "preview":
            guard let request = try? WebWire.body(WebPreviewRequest.self, from: text) else { return }
            peer.previewEnabled = request.enabled; setDemand()
        default: onMessage?(peer.id, kind, text)
        }
    }

    fileprivate var challengeCamera: String { cameraName }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Peer

    fileprivate final class Peer: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        weak var server: WebDisplayServer?
        var authenticated = false
        var previewEnabled = false
        var pendingBytes = 0
        var nonce = ""
        private var buffer = Data()
        private var websocket = false
        private var requestHandled = false
        private var decoder = WebSocketFrame.Decoder()
        private var ended = false
        private var opened = Date()
        private var lastReceive = Date()
        private var file: FileJob?

        private final class FileJob {
            let handle: FileHandle
            var offset: Int64
            let end: Int64
            let onFinish: (@Sendable () -> Void)?
            init(handle: FileHandle, offset: Int64, end: Int64, onFinish: (@Sendable () -> Void)?) {
                self.handle = handle; self.offset = offset; self.end = end; self.onFinish = onFinish
            }
        }

        init(connection: NWConnection, server: WebDisplayServer) { self.connection = connection; self.server = server }

        func start() {
            guard let server else { return }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            connection.start(queue: server.queue)
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, complete, error in
                guard let self, !self.ended else { return }
                if let data, !data.isEmpty { self.lastReceive = Date(); self.consume(data) }
                if error != nil || complete { self.close(); return }
                if !self.ended { self.receive() }
            }
        }

        private func consume(_ data: Data) {
            if websocket {
                do {
                    for (opcode, payload) in try decoder.append(data) {
                        switch opcode {
                        case .text: server?.received(payload, from: self)
                        case .ping: write(WebSocketFrame.encode(.pong, payload))
                        case .close: write(WebSocketFrame.encode(.close, Data())); close()
                        case .binary, .pong, .continuation: break
                        }
                        if ended { return }
                    }
                } catch { close() }
                return
            }
            // One request per connection (no keep-alive); anything after it is ignored.
            guard !requestHandled else { return }
            buffer.append(data)
            do {
                guard let (request, _) = try WebHTTPRequest.parse(buffer) else { return }
                buffer = Data(); requestHandled = true
                server?.route(request, peer: self)
            } catch { respond(400, error.localizedDescription) }
        }

        func beat(_ now: Date) {
            if websocket {
                if now.timeIntervalSince(lastReceive) > 20 { close(); return }
                write(WebSocketFrame.encode(.ping, Data()))
                if !authenticated, now.timeIntervalSince(opened) > 10 { close() }
            } else if file == nil, now.timeIntervalSince(lastReceive) > 30 { close() }
        }

        // MARK: WebSocket

        func upgrade(key: String, nonce: String) {
            self.nonce = nonce; websocket = true; opened = Date()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocketFrame.acceptKey(key))\r\n\r\n"
            write(Data(head.utf8))
            let challenge = WebAuthChallenge(nonce: nonce, camera: server?.challengeCamera ?? "")
            if let data = try? WebWire.envelope("auth", challenge) { write(WebSocketFrame.encode(.text, data)) }
            // An unauthenticated socket gets 5 seconds.
            server?.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.ended, !self.authenticated else { return }
                self.close()
            }
        }
        func authFailed(_ message: String, close shouldClose: Bool) {
            if let data = try? WebWire.envelope("auth", WebAuthResult(ok: false, message: message)) { sendText(data, force: true) }
            if shouldClose { server?.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.close() } }
        }
        func sendText(_ data: Data, force: Bool = false) {
            guard websocket, authenticated || force else { return }
            write(WebSocketFrame.encode(.text, data))
        }
        func sendBinary(_ data: Data) { guard websocket, authenticated else { return }; write(WebSocketFrame.encode(.binary, data)) }

        private func write(_ data: Data, completion: (() -> Void)? = nil) {
            guard !ended else { return }
            if websocket, pendingBytes + data.count > WebDisplayServer.controlBacklogLimit { close(); return }
            pendingBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.pendingBytes = max(0, self.pendingBytes - data.count)
                if error != nil { self.close(); return }
                completion?()
            })
        }

        // MARK: HTTP responses

        func respond(_ status: Int, _ message: String) {
            let body = Data(message.utf8)
            write(Self.head(status, ["Content-Type": "text/plain; charset=utf-8", "Content-Length": "\(body.count)"]) + body) { [weak self] in self?.finish() }
        }

        func serve(_ response: WebHTTPResponse, request: WebHTTPRequest) {
            guard !ended else { if case .file(_, _, _, let done) = response { done?() }; return }
            switch response {
            case .error(let status, let message): respond(status, message)
            case .json(let body):
                write(Self.head(200, ["Content-Type": "application/json; charset=utf-8", "Content-Length": "\(body.count)",
                                      "Cache-Control": "no-store"]) + (request.method == "HEAD" ? Data() : body)) { [weak self] in self?.finish() }
            case .file(let url, let type, let name, let done):
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? -1
                guard size >= 0, let handle = try? FileHandle(forReadingFrom: url) else { done?(); respond(404, courtText("文件不存在。")); return }
                var headers = ["Content-Type": type, "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
                if let name { headers["Content-Disposition"] = "attachment; filename=\"\(name)\"" }
                var status = 200, range: ClosedRange<Int64> = 0...max(0, size - 1)
                if request.headers["range"] != nil {
                    guard let requested = request.byteRange(size: size) else {
                        try? handle.close(); done?()
                        write(Self.head(416, ["Content-Range": "bytes */\(size)", "Content-Length": "0"])) { [weak self] in self?.finish() }
                        return
                    }
                    status = 206; range = requested
                    headers["Content-Range"] = "bytes \(requested.lowerBound)-\(requested.upperBound)/\(size)"
                }
                let length = size == 0 ? 0 : range.upperBound - range.lowerBound + 1
                headers["Content-Length"] = "\(length)"
                write(Self.head(status, headers))
                guard request.method == "GET", length > 0 else { try? handle.close(); done?(); finishAfterSend(); return }
                do { try handle.seek(toOffset: UInt64(range.lowerBound)) } catch { try? handle.close(); done?(); close(); return }
                file = FileJob(handle: handle, offset: range.lowerBound, end: range.upperBound + 1, onFinish: done)
                pump()
            }
        }

        private func pump() {
            guard let job = file, !ended else { return }
            while pendingBytes < WebDisplayServer.fileBacklog, job.offset < job.end {
                let count = Int(min(Int64(WebDisplayServer.fileChunk), job.end - job.offset))
                guard let data = try? job.handle.read(upToCount: count), !data.isEmpty else { endFile(); close(); return }
                job.offset += Int64(data.count)
                let last = job.offset >= job.end
                write(data) { [weak self] in
                    guard let self else { return }
                    if last { self.endFile(); self.finish() } else { self.pump() }
                }
                if last { return }
            }
        }
        private func endFile() {
            guard let job = file else { return }
            file = nil; try? job.handle.close(); job.onFinish?()
        }
        private func finishAfterSend() {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.close() })
        }
        private func finish() { finishAfterSend() }

        static func head(_ status: Int, _ headers: [String: String]) -> Data {
            let reason = [101: "Switching Protocols", 200: "OK", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized",
                          404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 416: "Range Not Satisfiable",
                          500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
            var text = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
            return Data((text + "\r\n").utf8)
        }

        func close() {
            guard !ended else { return }
            ended = true
            endFile()
            connection.stateUpdateHandler = nil
            connection.cancel()
            server?.closed(self)
        }
    }
}
