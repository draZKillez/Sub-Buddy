import XCTest
@testable import MKVSubtitleCore

final class MovieTitleResolverTests: XCTestCase {
    func testCleansCommonReleaseTokensAndFindsYear() {
        let url = URL(fileURLWithPath: "/Movies/The.Matrix.1999.2160p.UHD.BluRay.HDR.DV.x265.DTS-HD.MA.7.1-FGT.mkv")
        let result = MovieTitleResolver().resolve(fileURL: url, containerTitle: nil)
        XCTAssertEqual(result.originalTitle, "The Matrix")
        XCTAssertEqual(result.year, 1999)
    }

    func testContainerTitleHasPriority() {
        let url = URL(fileURLWithPath: "/Movies/Wrong.File.Name.1080p.mkv")
        let result = MovieTitleResolver().resolve(fileURL: url, containerTitle: "Arrival (2016)")
        XCTAssertEqual(result.originalTitle, "Arrival")
        XCTAssertEqual(result.year, 2016)
    }

    func testContainerTitleUsesFileNameAsYearFallback() {
        let url = URL(fileURLWithPath: "/Movies/Arrival.2016.1080p.mkv")
        let result = MovieTitleResolver().resolve(fileURL: url, containerTitle: "Arrival")
        XCTAssertEqual(result.originalTitle, "Arrival")
        XCTAssertEqual(result.year, 2016)
    }

    func testHandlesSpacesAndReleaseGroup() {
        let url = URL(fileURLWithPath: "/Movies/Everything Everywhere All at Once 2022 WEB-DL 1080p H264-NTb.mkv")
        let result = MovieTitleResolver().resolve(fileURL: url, containerTitle: nil)
        XCTAssertEqual(result.originalTitle, "Everything Everywhere All at Once")
        XCTAssertEqual(result.year, 2022)
    }
}
