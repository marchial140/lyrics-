import XCTest
@testable import LyricLive

final class LyricsTimelineTests: XCTestCase {
    func testMultipleTagsFractionsMetadataAndSorting() {
        let lines = LyricsTimeline.parse("[ar:Original demo]\n[00:12.250]Troisième\n[00:01.5][00:07.05]Refrain")
        XCTAssertEqual(lines.map(\.time), [1.5, 7.05, 12.25])
        XCTAssertEqual(lines.map(\.text), ["Refrain", "Refrain", "Troisième"])
    }

    func testBeforeFirstLineExactBoundaryPauseAndBackwardSeek() {
        let lines = LyricsTimeline.parse("[00:05]Première\n[00:10]Deuxième")
        XCTAssertNil(LyricsTimeline.index(at: 4.999, in: lines))
        XCTAssertEqual(LyricsTimeline.index(at: 5, in: lines), 0)
        XCTAssertEqual(LyricsTimeline.index(at: 10, in: lines), 1)
        XCTAssertEqual(LyricsTimeline.index(at: 10, in: lines), 1)
        XCTAssertEqual(LyricsTimeline.index(at: 6, in: lines), 0)
    }

    func testInstrumentalGapIsKeptAndDuplicateTimestampHasLastValue() {
        let lines = LyricsTimeline.parse("[00:01]Ancienne\n[00:01]Corrigée\n[00:03]\n[00:06]Suite")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].text, "Corrigée")
        XCTAssertEqual(lines[1].text, "")
        XCTAssertEqual(LyricsTimeline.index(at: 4, in: lines), 1)
    }

    func testPositiveOffsetAdvancesLyricsAndInvalidSecondsAreIgnored() {
        let lines = LyricsTimeline.parse("[offset:500]\n[00:01.500]Première\n[00:99]Invalide\n[00:04]Suite")
        XCTAssertEqual(lines.map(\.time), [1, 3.5])
        XCTAssertTrue(LyricsTimeline.parse("[ar:Demo]\nPas de timestamps").isEmpty)
        XCTAssertNil(LyricsTimeline.index(at: 10, in: []))
    }
}
