#if os(macOS)
import XCTest
import Foundation
import Network
@testable import CourtCore
@testable import CourtApp

/// Phase 3 connection options. Peer-to-peer Wi-Fi itself needs two devices without a shared
/// network; these tests cover the parts a single Mac can check: the ticket flag, path reporting
/// over loopback, the waiting grace and the display setting.
final class ConnectionPathTests: XCTestCase {
    func testTicketCarriesPeerToPeerAndOlderTicketsStayOff() throws {
        let ticket = try PairingTicket(name: "Test", peerToPeer: true)
        XCTAssertEqual(try PairingTicket.parse(ticket.url()).peerToPeer, true)
        XCTAssertTrue(ticket.parameters().includePeerToPeer)
        // A ticket from an earlier build has no flag: peer-to-peer stays off.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ticket)) as? [String: Any])
        object.removeValue(forKey: "peerToPeer")
        var parts = URLComponents(string: "zackscourt://pair")!
        parts.queryItems = [URLQueryItem(name: "ticket", value: try JSONSerialization.data(withJSONObject: object).base64EncodedString())]
        let older = try PairingTicket.parse(try XCTUnwrap(parts.string))
        XCTAssertNil(older.peerToPeer)
        XCTAssertFalse(older.parameters().includePeerToPeer)
        XCTAssertEqual(LinkPath(interface: "awdl0"), .peerToPeer)
        XCTAssertEqual(LinkPath(interface: "en0"), .localNetwork)
        XCTAssertEqual(LinkPath(interface: "bridge100"), .localNetwork)
        XCTAssertEqual(LinkPath(interface: "lo0"), .loopback)
        XCTAssertEqual(LinkPath(interface: nil), .other)
    }

    /// A refused connection reports `.waiting`; with a grace it fails only after the grace.
    func testWaitingGraceDelaysTheFailureOfAnUnreadyConnection() throws {
        let port = try unusedPort()
        func closeTime(grace: Double) throws -> Double {
            let queue = DispatchQueue(label: "court.test.grace")
            let ticket = try PairingTicket(name: "Test", peerToPeer: false)
            let connection = CourtConnection(NWConnection(host: "127.0.0.1", port: port, using: ticket.parameters()), queue: queue)
            connection.waitingGrace = grace
            let closed = expectation(description: "closed")
            let started = Date(); var elapsed = 0.0
            connection.onClose = { _ in elapsed = Date().timeIntervalSince(started); closed.fulfill() }
            queue.async { connection.start() }
            wait(for: [closed], timeout: 10)
            return elapsed
        }
        XCTAssertLessThan(try closeTime(grace: 0), 1)
        let graced = try closeTime(grace: 1.5)
        XCTAssertGreaterThanOrEqual(graced, 1.4)
        XCTAssertLessThan(graced, 4)
    }

    @MainActor func testBothEndsReportTheLinkPathAndTheSettingKeepsTheKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("court-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removeObject(forKey: "court.display.peerToPeer") }
        UserDefaults.standard.removeObject(forKey: "court.display.peerToPeer")
        let display = WorkspaceModel(storageDirectory: root.appendingPathComponent("display"))
        let rig = CameraRig(root: root.appendingPathComponent("camera"))
        do {
            XCTAssertTrue(display.peerToPeerEnabled, "Peer-to-peer listening is on by default")
            display.selectRole(.server)
            try await waitFor("ticket", timeout: 10) { !display.pairingURL.isEmpty }
            let first = try PairingTicket.parse(display.pairingURL)
            XCTAssertEqual(first.peerToPeer, true)
            // Turning it off keeps the key; the new code says the display no longer listens peer-to-peer.
            display.setPeerToPeer(false)
            try await waitFor("new code", timeout: 10) { !display.pairingURL.isEmpty && (try? PairingTicket.parse(display.pairingURL).peerToPeer) == false }
            var ticket = try PairingTicket.parse(display.pairingURL)
            XCTAssertEqual(ticket.key, first.key)
            XCTAssertEqual(ticket.service, first.service)
            display.setPeerToPeer(true)
            try await waitFor("peer-to-peer again", timeout: 10) { !display.pairingURL.isEmpty && (try? PairingTicket.parse(display.pairingURL).peerToPeer) == true }
            ticket = try PairingTicket.parse(display.pairingURL); ticket.host = "127.0.0.1"
            rig.camera.pair(ticket)
            try await waitFor("both ends know the path", timeout: 10) { display.linkPath != nil && rig.camera.linkPath != nil }
            XCTAssertEqual(display.linkPath, .loopback)
            XCTAssertEqual(rig.camera.linkPath, .loopback)
            // The setting cannot change under a connected camera.
            display.setPeerToPeer(false)
            XCTAssertTrue(display.peerToPeerEnabled)
            XCTAssertNotNil(display.error)
        } catch {
            await rig.close(); await display.shutdown(); throw error
        }
        await rig.close(); await display.shutdown()
    }

    private func unusedPort() throws -> NWEndpoint.Port {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(socket) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var bound = address, length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) } }
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(bigEndian: bound.sin_port)))
    }
    @MainActor private func waitFor(_ condition: String, timeout: Double, predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CourtError.message("Timed out waiting for \(condition)") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}
#endif
