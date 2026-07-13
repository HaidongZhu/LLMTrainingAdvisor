import Foundation
import Testing
@testable import TrainingApp

@Suite("ActivityParser")
struct ActivityParserTests {

    @Test("parses soccer with duration and intensity")
    func testParseSoccer() {
        let result = ActivityParser.parse("今天踢了60分钟，中等强度")
        #expect(result != nil)
        #expect(result?.type == "Soccer")
        #expect(result?.durationMin == 60)
        #expect(result?.intensity == "medium")
    }

    @Test("parses running with distance")
    func testParseRunning() {
        let result = ActivityParser.parse("跑了3公里")
        #expect(result != nil)
        #expect(result?.type == "Running")
        #expect(result?.distanceKm == 3.0)
    }

    @Test("parses soccer without watch")
    func testParseSoccerNoWatch() {
        let result = ActivityParser.parse("没戴表的比赛，90分钟")
        #expect(result != nil)
        #expect(result?.type == "Soccer")
        #expect(result?.durationMin == 90)
    }

    @Test("parses cycling with hours")
    func testParseWithHours() {
        let result = ActivityParser.parse("骑了2小时")
        #expect(result != nil)
        #expect(result?.type == "Cycling")
        #expect(result?.durationMin == 120)
    }

    @Test("parses hiking with distance")
    func testParseHiking() {
        let result = ActivityParser.parse("爬了5公里山")
        #expect(result != nil)
        #expect(result?.type == "Hiking")
        #expect(result?.distanceKm == 5.0)
    }

    @Test("returns nil for empty string")
    func testParseEmpty() {
        let result = ActivityParser.parse("")
        #expect(result == nil)
    }

    @Test("returns nil for unrelated message")
    func testParseUnrelated() {
        let result = ActivityParser.parse("今天天气很好")
        #expect(result == nil)
    }

    @Test("parses strength training")
    func testParseStrength() {
        let result = ActivityParser.parse("练腿了")
        #expect(result != nil)
        #expect(result?.type == "Strength")
    }
}
