import UIKit
import XCTest
@testable import SimPilotEFB

final class ChartPackTests: XCTestCase {
    @MainActor
    func testPinPersistsAllPagesAndDistinctFileNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pack = ChartPack(directory: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }

        pack.add(icao: "EGSS", detail: chart("test/a"), images: [0: image])
        pack.add(icao: "EGSS", detail: chart("test_a"), images: [0: image])
        let restored = ChartPack(directory: directory)
        XCTAssertEqual(restored.items.count, 2)
        let paths = restored.items.compactMap { $0.detail.pages.first?.image }
        XCTAssertEqual(Set(paths).count, 2)
        for path in paths {
            XCTAssertNotNil(UIImage(contentsOfFile: directory.appendingPathComponent(String(path.dropFirst(5))).path))
        }
        restored.remove("test/a")
        XCTAssertEqual(ChartPack(directory: directory).items.map(\.id), ["test_a"])
    }

    @MainActor
    func testIncompleteOrFailedSaveNeverClaimsPinned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pack = ChartPack(directory: directory)
        pack.add(icao: "EGSS", detail: chart("missing-page"), images: [:])
        XCTAssertTrue(pack.items.isEmpty)
        XCTAssertNotNil(pack.error)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        // A directory at the index path makes the atomic manifest write fail after image download.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("pack.json"), withIntermediateDirectories: true)
        pack.add(icao: "EGSS", detail: chart("failed-write"), images: [0: image])
        XCTAssertTrue(pack.items.isEmpty)
        XCTAssertNotNil(pack.error)
    }

    @MainActor
    private func chart(_ guid: String) -> ChartDetail {
        ChartDetail(chart: ChartMeta(guid: guid, type: "AGC", name: "Test", runways: [], procedures: [], geoReferenced: false, pageCount: 1, validFrom: nil, validUntil: nil),
                    pages: [ChartPage(index: 0, width: 2, height: 2, geoReferenced: false, areas: [], image: "/test.png")])
    }
}
