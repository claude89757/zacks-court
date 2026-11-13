import XCTest
@testable import CourtCore

/// Typed shot reasons: every engine string has plain wording, and the wire stays readable both ways.
final class TennisReasonTests: XCTestCase {
    /// Every reason string the engine, the flight estimator and the camera-side analyzer emit.
    static let engineStrings = [
        "等待首弹地及连续三维轨迹", "等待独立队列触地定位",
        "缺少击球轨迹样本", "飞行时长不在已支持范围", "源帧计数与时间戳不一致", "需要至少四个连续击球轨迹样本",
        "速度拟合时间跨度不足", "三维轨迹拟合残差过大", "模型速度超出支持范围", "端点与轨迹速度不一致",
        "端点与轨迹方向不一致", "水平运动方向不一致", "弹地三维模型位置不可用",
        "下一段击球前没有可靠首弹地证据", "会话结束前没有可靠首弹地证据", "超过已支持的飞行时间，未确认首弹地",
        "首弹地前检测到触网候选", "首弹地前出现其他事件",
        "Focus球位置缺失、低分或存在竞争目标", "触地候选缺少受支持的球场映射", "模型弹地候选，未验证物理触地或判线精度",
        "设备降载期间未做触地定位", "触地定位队列繁忙，未定位", "触地定位失败：内存不足",
    ]

    func testEveryEngineStringHasPlainWording() throws {
        for detail in Self.engineStrings {
            let kind = TennisReason.classify(detail)
            XCTAssertNotEqual(kind, .other, detail)
            XCTAssertFalse(kind.text.isEmpty)
            XCTAssertFalse(kind.text.contains("Focus") || kind.text.contains("三维") || kind.text.contains("队列"), kind.text)
        }
        XCTAssertTrue(TennisReason.classify("等待首弹地及连续三维轨迹").isPending)
        XCTAssertTrue(TennisReason.classify("等待独立队列触地定位").isPending)
        XCTAssertEqual(TennisReason.classify("三维轨迹拟合残差过大").text, "球速不可靠，未计入")
        XCTAssertEqual(TennisReason.classify("Focus球位置缺失、低分或存在竞争目标").text, "没看清球")
        XCTAssertEqual(TennisReason.classify("一条以后才有的原因"), .other)
    }

    /// The table is a match key. An English UI still has to recognise the engine's Chinese wording,
    /// then show the short reason through `text`.
    func testEngineMatchKeysIgnoreTheDisplayLanguage() {
        CourtCopy.withLanguage("en") {
            XCTAssertEqual(TennisReason.classify("设备降载期间未做触地定位"), .cameraCooling)
            XCTAssertEqual(TennisReason.classify("触地定位队列繁忙，未定位"), .cameraBusy)
            XCTAssertEqual(TennisReason.classify("触地定位失败：内存不足"), .failed)
            XCTAssertEqual(TennisReason.classify("缺少击球轨迹样本"), .ballNotSeen)
            XCTAssertEqual(TennisReason.classify("等待首弹地及连续三维轨迹"), .pending)
            XCTAssertEqual(TennisReason.classify("下一段击球前没有可靠首弹地证据"), .noBounceSeen)
            XCTAssertEqual(TennisReason.classify("Focus球位置缺失、低分或存在竞争目标"), .ballNotSeen)
        }
    }

    func testEventsCarryTheCodeAndExplainMissingValues() {
        let stream = UUID()
        var shot = TennisShotEvent(streamID: stream, sourcePTS: 1, stroke: .forehand, confidence: 0.9, speedReason: "等待首弹地及连续三维轨迹")
        XCTAssertEqual(shot.speedReasonCode, .pending)
        XCTAssertEqual(shot.placementReasonKind, .pending, "No bounce while the ball is still in flight")
        shot.setSpeedReason("三维轨迹拟合残差过大")
        XCTAssertEqual(shot.speedReasonText, "球速不可靠，未计入")
        XCTAssertEqual(shot.placementReasonKind, .noBounceSeen)
        shot.bounce = .init(sourcePTS: 1.5, confidence: 0, reason: "触地候选缺少受支持的球场映射")
        XCTAssertEqual(shot.placementReasonKind, .notOnCourt)
        shot.speedKPH = 120
        XCTAssertNil(shot.speedReasonText, "A usable speed has no reason")
        shot.bounce = .init(sourcePTS: 1.5, xMeters: 4, yMeters: 18, confidence: 0.7, reason: "模型弹地候选，未验证物理触地或判线精度")
        XCTAssertNil(shot.placementReasonText, "A landing spot on the court map has no reason")
    }

    /// An older v2 camera sends only the strings; the rows still decode and read plainly.
    func testOldStringOnlyPayloadDecodes() throws {
        let json = #"""
        {"id":"8D7C6B5A-0000-4000-8000-000000000001","streamID":"8D7C6B5A-0000-4000-8000-000000000002","sourcePTS":3,
         "endPTS":3.6,"stroke":"backhand","confidence":0.7,"speedReason":"端点与轨迹方向不一致",
         "bounce":{"sourcePTS":3.6,"confidence":0,"reason":"Focus球位置缺失、低分或存在竞争目标"},"sampleCount":5}
        """#
        let shot = try JSONDecoder().decode(TennisShotEvent.self, from: Data(json.utf8))
        XCTAssertNil(shot.speedReasonCode)
        XCTAssertEqual(shot.speedReasonKind, .speedUnreliable)
        XCTAssertEqual(shot.placementReasonKind, .ballNotSeen)
        XCTAssertEqual(shot.placementReasonText, "没看清球")
    }

    /// A newer camera may send a code this build does not know: decoding must not fail.
    func testUnknownCodeDecodesAsOther() throws {
        let json = #"""
        {"id":"8D7C6B5A-0000-4000-8000-000000000001","streamID":"8D7C6B5A-0000-4000-8000-000000000002","sourcePTS":3,
         "stroke":"serve","confidence":0.7,"speedReason":"新原因","speedReasonCode":"somethingNew","sampleCount":1,
         "bounce":{"sourcePTS":3.6,"confidence":0,"reasonCode":"alsoNew"}}
        """#
        let shot = try JSONDecoder().decode(TennisShotEvent.self, from: Data(json.utf8))
        XCTAssertEqual(shot.speedReasonCode, .other)
        XCTAssertEqual(shot.bounce?.reasonCode, .other)
        XCTAssertEqual(shot.speedReasonText, TennisReason.other.text)
    }

    /// The native link and saved sessions carry codes only; the browser JSON adds the display text.
    func testDisplayTextOnlyInBrowserJSON() throws {
        let shot = TennisShotEvent(streamID: UUID(), sourcePTS: 1, stroke: .serve, confidence: 0.8, speedReason: "三维轨迹拟合残差过大")
        let native = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shot)) as? [String: Any])
        XCTAssertEqual(native["speedReasonCode"] as? String, "speedUnreliable")
        XCTAssertEqual(native["speedReason"] as? String, "三维轨迹拟合残差过大", "Engine wording stays for older peers")
        XCTAssertNil(native["speedReasonText"])
        let web = try XCTUnwrap(JSONSerialization.jsonObject(with: WebWire.encoder.encode(shot)) as? [String: Any])
        XCTAssertEqual(web["speedReasonText"] as? String, "球速不可靠，未计入")
        XCTAssertEqual(web["placementReasonText"] as? String, "没看到球落地")
        // Round trip through the browser JSON: the extra keys are ignored.
        let back = try WebWire.decoder.decode(TennisShotEvent.self, from: WebWire.encoder.encode(shot))
        XCTAssertEqual(back, shot)
    }
}
