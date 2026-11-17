import XCTest
@testable import SimPilotEFB

final class BridgeResponseLimitTests: XCTestCase {
    func testStreamEnforcesTheLimitWithoutAContentLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeResponseFixture.self]
        configuration.timeoutIntervalForRequest = 3
        let delegate = BridgeSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://bridge.test/chart")!)
        let (data, _) = try await delegate.load(request, session: session, maximumBytes: 4)
        XCTAssertEqual(data, Data("test".utf8))
        let unfinished = URLRequest(url: URL(string: "https://bridge.test/unfinished")!)
        do {
            _ = try await delegate.load(unfinished, session: session, maximumBytes: 3)
            XCTFail("Accepted a response larger than its limit")
        } catch let error as BridgeClient.HTTPError {
            XCTAssertEqual(error.status, 413)
        }
    }

    func testChartImagePixelLimit() {
        XCTAssertTrue(BridgeImageLimit.supportsDimensions(width: 6000, height: 6000))
        XCTAssertFalse(BridgeImageLimit.supportsDimensions(width: 7000, height: 7000))
        XCTAssertFalse(BridgeImageLimit.supportsDimensions(width: 12_001, height: 1))
        XCTAssertFalse(BridgeImageLimit.supportsDimensions(width: 0, height: 100))
    }

    func testImportedPdfSizeLimit() {
        XCTAssertTrue(DocumentFiles.supportsImportSize(100 * 1024 * 1024))
        XCTAssertFalse(DocumentFiles.supportsImportSize(100 * 1024 * 1024 + 1))
        XCTAssertFalse(DocumentFiles.supportsImportSize(-1))
    }
}

private final class BridgeResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("te".utf8))
        client?.urlProtocol(self, didLoad: Data("st".utf8))
        if request.url?.path == "/chart" {
            client?.urlProtocolDidFinishLoading(self)
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                self.client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: 64 * 1024))
            }
        }
    }

    override func stopLoading() {}
}
