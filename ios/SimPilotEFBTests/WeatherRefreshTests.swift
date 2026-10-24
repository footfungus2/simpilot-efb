import Foundation
import XCTest
@testable import SimPilotEFB

final class WeatherRefreshTests: XCTestCase {
    @MainActor func testRepeatedMapUpdatesDoNotRestartOrCancelAnActiveDownload() async throws {
        WeatherProtocol.reset()
        URLProtocol.registerClass(WeatherProtocol.self)
        defer { URLProtocol.unregisterClass(WeatherProtocol.self) }
        let store = WeatherStore()
        store.update(metars: true, sigmets: false, offsetHours: 0, flightAirports: [])
        store.mapAppeared()
        defer { store.mapDisappeared() }
        for _ in 0..<100 {
            store.update(metars: true, sigmets: false, offsetHours: 0, flightAirports: [])
            store.refreshIfStale()
        }
        for _ in 0..<500 {
            if store.status[.metars]?.updated != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(store.status[.metars]?.updated)
        XCTAssertNil(store.status[.metars]?.error)
        for _ in 0..<100 { store.refreshIfStale() }
        XCTAssertEqual(WeatherProtocol.requestCount, 1)
    }
}

private final class WeatherProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "aviationweather.gov" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        let data = Data(([WeatherSamples.metarHeader] + WeatherSamples.metarRows).joined(separator: "\n").utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
