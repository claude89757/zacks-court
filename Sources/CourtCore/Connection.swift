import Foundation
import Network

/// All callbacks run on `queue`. Control-plane messages always go out; preview frames only when
/// the send backlog is small, so analysis data never waits behind video.
public final class CourtConnection {
    /// Close reason when the other end hung up. Role-agnostic: each side shows its own wording
    /// (「机位已断开」 on the display, 「看板已断开」 on the camera).
    public static let peerClosed = "对端已断开"
    public let queue: DispatchQueue
    public var onPacket: ((StreamPacket) -> Void)?
    public var onReady: (() -> Void)?
    public var onClose: ((String) -> Void)?
    public var onFailure: ((NWError) -> Void)?
    public var onSendFinished: (() -> Void)?
    /// Interface the connection runs over, on ready and whenever the path changes.
    public var onPath: ((LinkPath, String?) -> Void)?
    /// Seconds a not-yet-ready connection may stay in `.waiting` before it counts as failed.
    /// Peer-to-peer Wi-Fi often waits a moment while the link comes up; 0 fails at once.
    public var waitingGrace = 0.0
    public private(set) var pendingBytes = 0
    public private(set) var isReady = false
    /// Set when the peer runs another protocol version; reconnecting cannot help.
    public private(set) var incompatible = false
    /// True once TLS completed, so a failed handshake is not reported as a disconnect.
    public private(set) var wasReady = false
    public static let previewBacklogLimit = 64 * 1024
    public var canAcceptPreview: Bool { isReady && pendingBytes < Self.previewBacklogLimit }
    private let connection: NWConnection
    private var decoder = PacketDecoder()
    private var ended = false
    private var lastReceive = Date()
    private var timer: DispatchSourceTimer?
    private var waitingSince: Date?
    public private(set) var interfaceName: String?

    public init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection; self.queue = queue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.ended else { return }
            if case .waiting = state {} else { self.waitingSince = nil }
            switch state {
            case .ready:
                self.isReady = true; self.wasReady = true
                // After onReady, so a display adopting this connection there also takes its path.
                self.onReady?(); self.reportPath(self.connection.currentPath); self.receive()
            case .failed(let error): self.onFailure?(error); self.close("连接失败：\(error.localizedDescription)")
            // Refused or unreachable: report instead of letting Network.framework wait silently,
            // so the camera's own backoff (and address/Bonjour alternation) runs.
            case .waiting(let error) where !self.wasReady:
                if self.waitingGrace <= 0 { self.onFailure?(error); self.close("无法连接：\(error.localizedDescription)"); break }
                guard self.waitingSince == nil else { break }
                self.waitingSince = Date()
                self.queue.asyncAfter(deadline: .now() + self.waitingGrace) { [weak self] in
                    guard let self, !self.ended, !self.isReady, self.waitingSince != nil else { return }
                    self.onFailure?(error); self.close("无法连接：\(error.localizedDescription)")
                }
            case .cancelled: self.close("连接已断开")
            default: break
            }
        }
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, !self.ended, self.isReady else { return }
            self.reportPath(path)
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReceive) > 12 { self.close("连接超时，请重新连接。") }
            else if self.isReady { self.send(StreamPacket(header: StreamHeader(kind: "status"))) }
        }
        timer.resume(); self.timer = timer
    }

    public func send(_ packet: StreamPacket) {
        guard isReady, !ended else { return }
        do {
            let data = try packet.encoded()
            guard pendingBytes + data.count <= 2 * PacketDecoder.maximumBody else {
                close("网络发送积压，连接已重置，重连后补发数据。"); return
            }
            pendingBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.pendingBytes = max(0, self.pendingBytes - data.count)
                if let error { self.close(error.localizedDescription) }
                self.onSendFinished?()
            })
        } catch { close(error.localizedDescription) }
    }

    private var pathReported = false
    private func reportPath(_ path: NWPath?) {
        let name = path?.availableInterfaces.first?.name
        if pathReported && name == interfaceName { return }
        pathReported = true; interfaceName = name
        onPath?(LinkPath(interface: name), name)
    }

    public func close(_ reason: String = "已断开") {
        guard !ended else { return }
        ended = true; isReady = false
        timer?.cancel(); timer = nil
        connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil
        connection.cancel(); onClose?(reason)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                self.lastReceive = Date()
                do { for packet in try self.decoder.append(data) { self.onPacket?(packet) } }
                catch {
                    if case CourtError.incompatible = error { self.incompatible = true }
                    self.close(error.localizedDescription); return
                }
            }
            if let error { self.close(error.localizedDescription) }
            else if complete { self.close(Self.peerClosed) }
            else { self.receive() }
        }
    }
}

/// Display-side listener. One camera at a time: a new authenticated connection replaces a stale
/// one (after a Wi-Fi blip the old socket can linger until its receive timeout).
public final class CourtServer {
    public let queue = DispatchQueue(label: "court.receiver")
    public var onListening: ((PairingTicket) -> Void)?
    public var onConnected: (() -> Void)?
    public var onPacket: ((StreamPacket) -> Void)?
    public var onDisconnected: ((String) -> Void)?
    public var onIncompatible: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    public var onConnectionFailure: ((NWError) -> Void)?
    /// Interface the current camera connection runs over.
    public var onPath: ((LinkPath, String?) -> Void)?
    private var listener: NWListener?
    private var client: CourtConnection?
    /// Connections still in the TLS handshake, retained until they are ready or closed.
    private var handshaking: [ObjectIdentifier: CourtConnection] = [:]
    private var ticket: PairingTicket?

    public init() {}
    /// `port` reuses the previous listening port so a camera holding the same ticket can return;
    /// if it is taken the listener falls back to any free port (the camera then finds it by Bonjour).
    public func start(ticket: PairingTicket, port: UInt16? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal(); self.ticket = ticket
            do { try self.listen(ticket: ticket, port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any) }
            catch {
                if port != nil, (try? self.listen(ticket: ticket, port: .any)) != nil { return }
                self.onError?(error.localizedDescription)
            }
        }
    }
    private func listen(ticket: PairingTicket, port: NWEndpoint.Port) throws {
        let listener = try NWListener(using: ticket.parameters(), on: port)
        listener.service = NWListener.Service(name: ticket.service, type: PairingTicket.serviceType)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, self.listener === listener else { return }
            switch state {
            case .ready:
                var resolved = ticket
                resolved.host = LocalNetwork.ipv4Addresses().first
                resolved.port = listener?.port?.rawValue
                self.onListening?(resolved)
            case .failed(let error):
                if port != .any, case .posix(let code) = error, code == .EADDRINUSE {
                    self.listener = nil; listener?.cancel()
                    do { try self.listen(ticket: ticket, port: .any) } catch { self.onError?(error.localizedDescription) }
                } else { self.onError?(error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener; listener.start(queue: queue)
    }
    public func send(_ packet: StreamPacket) { queue.async { [weak self] in self?.client?.send(packet) } }
    public func send(command: String) {
        var header = StreamHeader(kind: "control"); header.command = command
        send(StreamPacket(header: header))
    }
    public var isConnected: Bool { client?.isReady == true }
    public func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in self?.stopInternal(); completion?() }
    }
    public func disconnectClient(_ reason: String) { queue.async { [weak self] in self?.client?.close(reason) } }
    private func stopInternal() {
        let old = client; client = nil
        old?.onClose = nil; old?.close()
        let pending = handshaking.values; handshaking = [:]
        for connection in pending { connection.onClose = nil; connection.close() }
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
    }
    private func accept(_ connection: NWConnection) {
        guard let ticket, ticket.expires > Date() else { connection.cancel(); return }
        let client = CourtConnection(connection, queue: queue)
        client.onReady = { [weak self, weak client] in
            guard let self, let client else { return }
            self.handshaking.removeValue(forKey: ObjectIdentifier(client))
            // TLS-PSK succeeded, so this is our camera. Replace any stale predecessor.
            if let old = self.client, old !== client {
                // A stale socket of the same camera ignores this; a second camera stops retrying.
                old.onClose = nil; old.onPacket = nil
                if let notice = try? StreamPacket.message(.control, WireControl(.superseded)) { old.send(notice) }
                self.queue.asyncAfter(deadline: .now() + 0.3) { old.close("机位已重新连接") }
                self.client = client
                self.onDisconnected?("机位已重新连接")
            }
            self.client = client
            self.onConnected?()
        }
        client.onFailure = { [weak self] error in self?.onConnectionFailure?(error) }
        client.onPath = { [weak self, weak client] path, name in
            guard let self, self.client === client else { return }
            self.onPath?(path, name)
        }
        client.onPacket = { [weak self, weak client] packet in
            guard let self, self.client === client else { return }
            self.onPacket?(packet)
        }
        client.onClose = { [weak self, weak client] reason in
            guard let self, let client else { return }
            self.handshaking.removeValue(forKey: ObjectIdentifier(client))
            guard self.client === client else { return }
            self.client = nil
            if client.incompatible { self.onIncompatible?(reason) }
            if client.wasReady { self.onDisconnected?(reason) }
        }
        if self.client == nil { self.client = client } else { handshaking[ObjectIdentifier(client)] = client }
        client.start()
    }
}

/// Camera-side client that keeps reconnecting with backoff (alternating the ticket's address and
/// Bonjour lookup) until stopped, the ticket expires, or the peer is incompatible.
/// All callbacks run on `queue`.
public final class CameraLink: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting(attempt: Int)
        case connected
        /// Waiting before the next attempt; reason of the last disconnect.
        case waiting(String)
        /// Terminal: stop retrying and show the reason.
        case failed(String)
        case stopped
    }
    public let queue = DispatchQueue(label: "court.camera.link", qos: .userInitiated)
    public let ticket: PairingTicket
    public var onState: ((State) -> Void)?
    /// Connection authenticated; send hello/resync from here.
    public var onReady: (() -> Void)?
    public var onPacket: ((StreamPacket) -> Void)?
    /// Interface the connection runs over.
    public var onPath: ((LinkPath, String?) -> Void)?
    private var connection: CourtConnection?
    private var attempt = 0
    /// The last ready connection ran over peer-to-peer Wi-Fi: try Bonjour first next time.
    private var lastPeerToPeer = false
    private var running = false
    private var retry: DispatchWorkItem?
    private var file: FileJob?
    public static let backoff: [Double] = [0.5, 1, 2, 4, 8]

    private final class FileJob {
        let handle: FileHandle
        var header: StreamHeader
        var offset: Int64
        var sent = false
        let total: Int64
        let chunkSize: Int
        let backlogLimit: Int
        let completion: @Sendable (String?) -> Void
        init(handle: FileHandle, header: StreamHeader, offset: Int64, total: Int64, chunkSize: Int, backlogLimit: Int, completion: @escaping @Sendable (String?) -> Void) {
            self.handle = handle; self.header = header; self.offset = offset; self.total = total
            self.chunkSize = chunkSize; self.backlogLimit = backlogLimit; self.completion = completion
        }
    }

    /// Streams a file in `file` packets from `offset`, keeping at most `backlogLimit` unsent so
    /// control messages stay close behind. `header` carries session ID, file name, total and
    /// SHA-256. Completion runs once, on `queue`: nil when every chunk was handed to the network.
    /// One file at a time: a new call cancels the previous one.
    public func sendFile(_ url: URL, header: StreamHeader, offset: Int64, total: Int64,
                         chunkSize: Int = RecordingTransfer.chunkSize, backlogLimit: Int = RecordingTransfer.backlogLimit,
                         completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            finishFile("新的回传开始，上一份回传已取消。")
            guard let connection, connection.isReady else { completion("看板未连接。"); return }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.seek(toOffset: UInt64(max(0, offset)))
                file = FileJob(handle: handle, header: header, offset: max(0, offset), total: total,
                               chunkSize: max(1, chunkSize), backlogLimit: max(chunkSize, backlogLimit), completion: completion)
                pump()
            } catch { completion(error.localizedDescription) }
        }
    }
    public func cancelFile() { queue.async { [self] in finishFile("回传已取消。") } }

    private func pump() {
        guard let job = file, let connection, connection.isReady else { return }
        do {
            while connection.pendingBytes < job.backlogLimit, job.offset < job.total {
                let data = try job.handle.read(upToCount: job.chunkSize) ?? Data()
                guard !data.isEmpty else { throw CourtError.message("录像文件在回传中变短了。") }
                var header = job.header
                header.offset = job.offset
                connection.send(StreamPacket(header: header, payload: data))
                job.offset += Int64(data.count); job.sent = true
            }
            if job.offset >= job.total {
                // Resuming an already complete copy: one empty final chunk lets the display verify it.
                if !job.sent {
                    var header = job.header; header.offset = job.total
                    connection.send(StreamPacket(header: header))
                }
                finishFile(nil)
            }
        } catch { finishFile(error.localizedDescription) }
    }
    private func finishFile(_ failure: String?) {
        guard let job = file else { return }
        file = nil
        try? job.handle.close()
        job.completion(failure)
    }

    public init(ticket: PairingTicket) { self.ticket = ticket }

    public func start() { queue.async { [self] in guard !running else { return }; running = true; attempt = 0; connect() } }
    public func stop() {
        queue.async { [self] in
            running = false; retry?.cancel(); retry = nil
            let old = connection; connection = nil
            old?.onClose = nil; old?.close("已断开")
            onState?(.stopped)
        }
    }
    /// Reliable control-plane send; dropped while disconnected (the display resyncs on reconnect).
    public func send(_ packet: StreamPacket) { queue.async { [self] in connection?.send(packet) } }
    /// Best-effort preview frame; false when the backlog is not small enough and it was dropped.
    /// Call from any queue except `queue`.
    @discardableResult public func sendPreview(_ packet: StreamPacket) -> Bool {
        queue.sync {
            guard let connection, connection.canAcceptPreview else { return false }
            connection.send(packet); return true
        }
    }

    private func connect() {
        guard running else { return }
        guard ticket.expires > Date() else { running = false; onState?(.failed("配对已过期，请在看板上刷新配对码后重新扫码。")); return }
        attempt += 1
        // Attempts alternate between the ticket's address and a Bonjour lookup, which finds the
        // display when its listener moved to another port, or over peer-to-peer Wi-Fi when the two
        // devices share no network. After a peer-to-peer connection the lookup goes first.
        let bonjour = ticket.host == nil || ((attempt % 2 == 0) != lastPeerToPeer)
        let endpoint: NWEndpoint = bonjour
            ? .service(name: ticket.service, type: PairingTicket.serviceType, domain: "local.", interface: nil)
            : ticket.endpoint()
        let connection = CourtConnection(NWConnection(to: endpoint, using: ticket.parameters()), queue: queue)
        if bonjour && ticket.peerToPeer == true { connection.waitingGrace = 3 }
        self.connection = connection
        connection.onPath = { [weak self, weak connection] path, name in
            guard let self, self.connection === connection else { return }
            self.lastPeerToPeer = path == .peerToPeer
            self.onPath?(path, name)
        }
        onState?(.connecting(attempt: attempt))
        connection.onReady = { [weak self, weak connection] in
            guard let self, self.connection === connection else { return }
            self.attempt = 0
            self.onState?(.connected); self.onReady?()
        }
        connection.onPacket = { [weak self, weak connection] packet in
            guard let self, let connection, self.connection === connection else { return }
            if packet.wireKind == .control, (try? packet.decode(WireControl.self))?.command == .superseded {
                self.running = false; self.connection = nil
                connection.onClose = nil; connection.close("已被另一台机位取代")
                self.onState?(.failed("另一台机位已连接到这个看板，本机停止重连。要换用本机，先在看板上断开那台机位，再点「重连」。")); return
            }
            self.onPacket?(packet)
        }
        connection.onSendFinished = { [weak self, weak connection] in
            guard let self, self.connection === connection else { return }
            self.pump()
        }
        connection.onClose = { [weak self, weak connection] reason in
            guard let self, let connection, self.connection === connection else { return }
            self.connection = nil
            self.finishFile("连接中断：\(reason)")
            if connection.incompatible { self.running = false; self.onState?(.failed(reason)); return }
            self.scheduleRetry(reason)
        }
        connection.start()
    }
    private func scheduleRetry(_ reason: String) {
        guard running else { return }
        onState?(.waiting(reason))
        let delay = Self.backoff[min(max(0, attempt - 1), Self.backoff.count - 1)]
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
