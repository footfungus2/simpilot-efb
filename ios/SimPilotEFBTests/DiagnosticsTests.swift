import XCTest
@testable import SimPilotEFB

final class DiagnosticsTests: XCTestCase {
    func testConsoleIsBoundedAndClearable() {
        var buffer = DiagnosticBuffer()
        for i in 0...300 { buffer.append(.info, "Test", "Event \(i)") }
        XCTAssertEqual(buffer.entries.count, 300)
        XCTAssertEqual(buffer.entries.first?.message, "Event 1")
        XCTAssertEqual(buffer.entries.last?.message, "Event 300")
        buffer.clear()
        XCTAssertTrue(buffer.entries.isEmpty)
    }

    func testReportsRedactSensitiveDetailsAndBoundMessages() {
        var buffer = DiagnosticBuffer()
        buffer.append(.error, "Network", "https://example.com?username=alice token=abcd Bearer xyz user@example.com 192.168.1.2:8380 /Users/max/private\nforged line")
        let report = buffer.report(summary: ["password=secret"])
        for secret in ["username=alice", "abcd", "Bearer xyz", "user@example.com", "192.168.1.2", "/Users/max", "password=secret"] {
            XCTAssertFalse(report.contains(secret), secret)
        }
        XCTAssertFalse(buffer.entries[0].message.contains("\n"))
        buffer.append(.info, "Test", String(repeating: "a", count: 1000))
        XCTAssertEqual(buffer.entries.last?.message.count, 800)
    }

    func testBridgeAddresses() {
        XCTAssertEqual(BridgeAddress.normalize(" 192.168.1.2 "), "192.168.1.2:8387")
        XCTAssertEqual(BridgeAddress.normalize("192.168.1.2:8380"), "192.168.1.2:8387")
        XCTAssertEqual(BridgeAddress.normalize("192.168.1.2:8386"), "192.168.1.2:8387")
        XCTAssertEqual(BridgeAddress.normalize("http://flight-pc.local:8381/"), "flight-pc.local:8381")
        XCTAssertEqual(BridgeAddress.normalize("https://flight-pc.local"), "flight-pc.local:8387")
        for input in ["", "bad host", "http://user:secret@pc", "ftp://pc", "pc/path", "pc?token=1", "pc:0", "pc:99999"] {
            XCTAssertNil(BridgeAddress.normalize(input), input)
        }
    }

    func testBridgeResourcesStayOnThePairedOrigin() {
        let base = URL(string: "https://192.168.1.20:8387")!
        XCTAssertTrue(BridgeAddress.sameOrigin(URL(string: "/charts/EGSS/chart/0.png", relativeTo: base)!.absoluteURL, as: base))
        XCTAssertFalse(BridgeAddress.sameOrigin(URL(string: "http://192.168.1.21/private")!, as: base))
        XCTAssertFalse(BridgeAddress.sameOrigin(URL(string: "https://user@192.168.1.20:8387/private")!, as: base))
    }

    func testPairingCodeRequiresBothTheKeyAndCertificateFingerprint() {
        let key = String(repeating: "a", count: 64)
        let fingerprint = String(repeating: "b", count: 64)
        XCTAssertEqual(BridgePairingCode.parse(" \(key):\(fingerprint) "), BridgePairingCode(key: key, fingerprint: fingerprint))
        XCTAssertNil(BridgePairingCode.parse(key))
        XCTAssertNil(BridgePairingCode.parse("\(key):\(String(repeating: "z", count: 64))"))
    }

    func testRepeatedPCSnapshotDoesNotEvictAppLogs() {
        var buffer = DiagnosticBuffer()
        buffer.append(.error, "App", "Original failure", time: Date(timeIntervalSince1970: 0))
        for _ in 0..<2 {
            for i in 1...200 {
                buffer.append(.info, "PC", "Event \(i)", time: Date(timeIntervalSince1970: Double(i)))
            }
        }
        XCTAssertEqual(buffer.entries.count, 201)
        XCTAssertEqual(buffer.entries.first?.message, "Original failure")
    }
}
