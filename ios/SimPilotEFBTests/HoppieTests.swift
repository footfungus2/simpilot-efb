import XCTest
@testable import SimPilotEFB

final class HoppieProtocolTests: XCTestCase {
    func testPlainRepliesAndErrors() throws {
        XCTAssertTrue(try HoppieProtocol.parse("ok").isEmpty)
        XCTAssertThrowsError(try HoppieProtocol.parse("error {invalid logon code}")) { error in
            XCTAssertEqual(error.localizedDescription, "invalid logon code")
        }
        XCTAssertThrowsError(try HoppieProtocol.parse("<html>maintenance</html>"))
    }

    func testIncomingTelexAndCpdlc() throws {
        let reply = "ok {EGLL telex {CLEARED TO LIRA VIA CLN5S. SQUAWK 4521}} {EGTT cpdlc {/data2/12//WU/CLIMB TO @FL350}}"
        let messages = try HoppieProtocol.parse(reply)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].station, "EGLL")
        XCTAssertEqual(messages[0].text, "CLEARED TO LIRA VIA CLN5S. SQUAWK 4521")
        XCTAssertEqual(messages[1].cpdlcID, 12)
        XCTAssertEqual(messages[1].cpdlcReplyCode, "WU")
        XCTAssertEqual(messages[1].text, "CLIMB TO \nFL350")
        XCTAssertTrue(messages[1].needsPilotReply)
        XCTAssertFalse(messages[0].needsPilotReply)
        XCTAssertTrue(messages.allSatisfy(\.unread))
    }

    func testNestedBracesInAPacketSurvive() throws {
        let messages = try HoppieProtocol.parse("ok {SERVER inforeq {EGSS 021520Z 24012KT {RMK} Q1013}}")
        XCTAssertEqual(messages.first?.packet, "EGSS 021520Z 24012KT {RMK} Q1013")
    }

    func testRequestBodyIsFormEncoded() {
        let body = HoppieProtocol.body(logon: "ab c", from: "EZY128W", to: "EGSS_TWR", type: "telex", packet: "REQUEST PDC & MORE")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "logon=ab%20c&from=EZY128W&to=EGSS_TWR&type=telex&packet=REQUEST%20PDC%20%26%20MORE")
        XCTAssertEqual(HoppieProtocol.clean("a{b}c"), "a(b)c")
    }
}
