import Foundation
import CourtCore

@main struct ProtocolTests {
    static func main() throws {
        let suite = Self()
        try suite.testFragmentationAndCoalescingPreserveExactBytes()
        suite.testRejectsOversizedAndMalformedHeadersBeforeAllocation()
        try suite.testVideoRequiresClockAndIdentity()
        try suite.testVersionMismatchAndRetiredKindsAreRejected()
        try suite.testMessageBodiesRoundTripAndResyncChunks()
        try suite.testPairingRoundtripAndExpiredTicketRejection()
        suite.testAssemblerRejectsInvalidDirectInput()
        try runDomainChecks()
        print("PASS: v2 fragmentation, coalescing, payload identity, length limits, timestamp requirements, version mismatch, resync chunking, optional Phase 3 fields, pairing expiry")
    }
    func testFragmentationAndCoalescingPreserveExactBytes() throws {
        var header = StreamHeader(kind: "preview")
        header.streamID = UUID(); header.sequence = 9001; header.pts = 123.456789
        header.duration = 1 / 60; header.keyframe = false
        let payload = Data((0..<1024).map { UInt8($0 % 256) })
        let packet = StreamPacket(header: header, payload: payload)
        let encoded = try packet.encoded()
        var decoder = PacketDecoder(); var packets: [StreamPacket] = []
        for byte in encoded { packets += try decoder.append(Data([byte])) }
        expectEqual(packets.count, 1)
        expectEqual(packets[0].payload, payload)
        expectEqual(packets[0].header.pts, header.pts)
        expectEqual(try decoder.append(encoded + encoded).count, 2)
    }
    func testRejectsOversizedAndMalformedHeadersBeforeAllocation() {
        var decoder = PacketDecoder()
        expectThrows(try decoder.append(Data([0x7f, 0xff, 0xff, 0xff])))
        decoder = PacketDecoder()
        expectThrows(try decoder.append(Data([0, 0, 0, 4, 0, 1, 0, 0])))
    }
    func testVideoRequiresClockAndIdentity() throws {
        var decoder = PacketDecoder()
        expectThrows(try decoder.append(StreamPacket(header: StreamHeader(kind: "preview"), payload: Data([1])).encoded()))
    }
    func testVersionMismatchAndRetiredKindsAreRejected() throws {
        // A v1 peer (full video to the display) is rejected with an explicit, terminal reason.
        var old = StreamHeader(kind: "hello"); old.version = 1
        var decoder = PacketDecoder()
        do { _ = try decoder.append(StreamPacket(header: old).encoded()); preconditionFailure("v1 accepted") }
        catch CourtError.incompatible(let message) { precondition(message.contains("v1"), message) }
        decoder = PacketDecoder()
        expectThrows(try decoder.append(StreamPacket(header: StreamHeader(kind: "video"), payload: Data([1])).encoded()))
        decoder = PacketDecoder()
        // Empty status is the transport keepalive; JSON bodies ride on the other control kinds.
        expectEqual(try decoder.append(StreamPacket(header: StreamHeader(kind: "status")).encoded()).count, 1)
    }
    func testMessageBodiesRoundTripAndResyncChunks() throws {
        let stream = UUID()
        let rows = (0..<450).map { TennisShotEvent(streamID: stream, sourcePTS: Double($0), stroke: .forehand, confidence: 0.5) }
        let parts = WireAnalysis.resync(sessionID: UUID(), events: rows, calibration: nil, modelVersion: "m")
        expectEqual(parts.map(\.events.count), [200, 200, 50])
        expectEqual(parts.map(\.part), [0, 1, 2]); expectEqual(Set(parts.compactMap(\.parts)), [3])
        expectEqual(WireAnalysis.resync(sessionID: nil, events: [], calibration: nil, modelVersion: nil).count, 1)
        var decoder = PacketDecoder(); var decoded: [StreamPacket] = []
        for part in parts { decoded += try decoder.append(try StreamPacket.message(.analysis, part).encoded()) }
        let restored = try decoded.map { try $0.decode(WireAnalysis.self) }
        expectEqual(restored.flatMap(\.events).map(\.id), rows.map(\.id))
        var control = WireControl(.corners, sessionID: UUID()); control.clearCorners = true
        let reply = WireControl.reply(to: control, ok: false, message: "x")
        let echoed = try decoder.append(try StreamPacket.message(.control, reply).encoded())[0].decode(WireControl.self)
        expectEqual(echoed.replyTo, control.id); expectEqual(echoed.ok, false); expectEqual(echoed.command, .reply)
        // Phase 3 fields are optional: a hello without capabilities (earlier v2 builds) still decodes,
        // and a clip request keeps its stream and window.
        let older = try JSONDecoder().decode(WireHello.self, from: Data(#"{"role":"camera","device":"d","hardware":"h","app":"a"}"#.utf8))
        expectEqual(older.capabilities, nil)
        let hello = WireHello(role: .camera, device: "d", hardware: "h", app: "a", capabilities: [WireHello.clips])
        expectEqual(try decoder.append(try StreamPacket.message(.hello, hello).encoded())[0].decode(WireHello.self).capabilities, [WireHello.clips])
        var clip = WireControl(.clip, sessionID: UUID()); clip.stream = UUID(); clip.sourcePTS = 10; clip.endPTS = 15; clip.label = "clip-x.mov"
        let clipEcho = try decoder.append(try StreamPacket.message(.control, clip).encoded())[0].decode(WireControl.self)
        expectEqual(clipEcho.command, .clip); expectEqual(clipEcho.stream, clip.stream); expectEqual(clipEcho.endPTS, 15)
    }
    func testPairingRoundtripAndExpiredTicketRejection() throws {
        let ticket = try PairingTicket(name: "Test Mac")
        let parsed = try PairingTicket.parse(ticket.url())
        expectEqual(parsed.key, ticket.key); expectEqual(parsed.service, ticket.service)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ticket)) as! [String: Any]
        object["expires"] = 0
        let data = try JSONSerialization.data(withJSONObject: object)
        var components = URLComponents(string: "zackscourt://pair")!
        components.queryItems = [URLQueryItem(name: "ticket", value: data.base64EncodedString())]
        expectThrows(try PairingTicket.parse(components.string!))
    }
    func testAssemblerRejectsInvalidDirectInput() {
        var header = StreamHeader(kind: "preview")
        header.streamID = UUID(); header.sequence = 1; header.pts = 1
        header.duration = 1 / 60; header.keyframe = true
        header.parameterSets = [Data(), Data()]
        expectThrows(try H264SampleAssembler().sample(from: StreamPacket(header: header, payload: Data([1]))))
        header.duration = .infinity
        expectThrows(try H264SampleAssembler().sample(from: StreamPacket(header: header, payload: Data([1]))))
    }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "Expected equality: \(lhs) != \(rhs)", file: file, line: line)
}
func expectThrows<T>(_ body: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try body(); preconditionFailure("Expected rejection", file: file, line: line) } catch {}
}
