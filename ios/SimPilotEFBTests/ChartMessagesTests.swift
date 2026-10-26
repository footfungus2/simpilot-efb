import XCTest
@testable import SimPilotEFB

final class ChartMessagesTests: XCTestCase {
    private func decode(_ json: String) -> BridgeMessage? { BridgeMessage.decode(Data(json.utf8)) }

    func testChartListMessagesDecode() {
        guard case let .chartsReady(icao)? = decode(#"{"t":"chartsReady","icao":"EGSS"}"#) else { return XCTFail("chartsReady") }
        XCTAssertEqual(icao, "EGSS")
        guard case let .chartsError(errorIcao, message)? = decode(#"{"t":"chartsError","icao":"EGSS","message":"nope"}"#) else { return XCTFail("chartsError") }
        XCTAssertEqual(errorIcao, "EGSS")
        XCTAssertEqual(message, "nope")
    }

    func testPerChartMessagesDecode() {
        guard case let .chartReady(icao, guid)? = decode(#"{"t":"chartReady","icao":"EGSS","guid":"{abc}"}"#) else { return XCTFail("chartReady") }
        XCTAssertEqual(icao, "EGSS")
        XCTAssertEqual(guid, "{abc}")
        guard case let .chartProgress(_, progressGuid, done, total)? = decode(#"{"t":"chartProgress","icao":"EGSS","guid":"{abc}","done":1,"total":3}"#) else { return XCTFail("chartProgress") }
        XCTAssertEqual(progressGuid, "{abc}")
        XCTAssertEqual(done, 1)
        XCTAssertEqual(total, 3)
        guard case let .chartError(_, errorGuid, message)? = decode(#"{"t":"chartError","icao":"EGSS","guid":"{abc}","message":"window hidden"}"#) else { return XCTFail("chartError") }
        XCTAssertEqual(errorGuid, "{abc}")
        XCTAssertEqual(message, "window hidden")
    }

    func testMessagesWithoutAChartAreIgnored() {
        XCTAssertNil(decode(#"{"t":"chartReady","icao":"EGSS"}"#))
        XCTAssertNil(decode(#"{"t":"chartsProgress","icao":"EGSS","done":1,"total":3}"#))
    }
}
