import XCTest
import AVFoundation
@testable import LearnLanguage

/// 読み上げ速度の正規化→AVSpeechUtterance rate 写像のテスト。
final class SpeechServiceTests: XCTestCase {

    func testMinMaxMapToBounds() {
        XCTAssertEqual(SpeechService.utteranceRate(for: 0), AVSpeechUtteranceMinimumSpeechRate, accuracy: 0.0001)
        XCTAssertEqual(SpeechService.utteranceRate(for: 1), AVSpeechUtteranceMaximumSpeechRate, accuracy: 0.0001)
    }

    func testMidpointIsBetweenBounds() {
        let mid = SpeechService.utteranceRate(for: 0.5)
        XCTAssertGreaterThan(mid, AVSpeechUtteranceMinimumSpeechRate)
        XCTAssertLessThan(mid, AVSpeechUtteranceMaximumSpeechRate)
    }

    func testClampsOutOfRangeInput() {
        XCTAssertEqual(SpeechService.utteranceRate(for: -1), AVSpeechUtteranceMinimumSpeechRate, accuracy: 0.0001)
        XCTAssertEqual(SpeechService.utteranceRate(for: 2), AVSpeechUtteranceMaximumSpeechRate, accuracy: 0.0001)
    }
}
