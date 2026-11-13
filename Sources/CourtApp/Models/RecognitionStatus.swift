import Foundation
import CourtCore

/// 「识别状态」: what the camera's analysis recognises right now, as five rows (court mapping,
/// people in frame, shots, and how many recent shots got a speed or a landing spot, with the main
/// reason when they did not). Counts and states only; unknown stays "—", never 0.
struct RecognitionStatus: Equatable {
    enum Tone: Equatable { case good, idle, warning }
    struct Row: Equatable, Identifiable {
        /// Accessibility identifier, `court.recognition.<key>`.
        let id: String
        let title: String
        let value: String
        var detail: String?
        let tone: Tone
    }
    struct People: Equatable {
        var streamID: UUID
        var pts: Double
        var count: Int
    }
    struct Input {
        var isLive: Bool
        var calibration: TennisCourtCalibrationState?
        /// Camera load-shedding level: L1 pauses person detection, L2 pauses bounce localization (S家).
        var shed = 0
        /// The in-house lane: shedding slows its person detection instead, and landing points continue.
        var inHouse = false
        var people: People?
        /// Camera capture clock and stream, to tell a fresh people result from a stale one.
        var latestPTS: Double?
        var streamID: UUID?
        /// Session ledger in order (or recent rows outside a session).
        var events: [TennisShotEvent] = []
        /// The camera's picture moved in the last few seconds and shots are not being counted (in-house lane).
        var pictureMoving = false
    }

    /// Speed and landing rows count this many recent shots that are no longer waiting on a result.
    static let window = 20
    /// The camera keeps its last people result while detection is paused; older than this is stale.
    static let staleSeconds = 3.0

    var rows: [Row]

    init(_ input: Input) {
        rows = [Self.court(input), Self.people(input), Self.shots(input), Self.speed(input), Self.landing(input)]
    }

    // MARK: Rows

    static func court(_ input: Input) -> Row {
        let id = "court.recognition.court", title = courtText("球场")
        guard input.isLive else { return Row(id: id, title: title, value: "—", detail: courtText("收到实时画面后检查球场识别。"), tone: .idle) }
        guard let calibration = input.calibration else {
            return Row(id: id, title: title, value: courtText("球场映射未就绪"), detail: courtText("正在等待场地地标；缺少球场映射时不在球场图上绘制落点。"), tone: .idle)
        }
        guard calibration.isAvailable else {
            let reason = calibration.reason.flatMap { $0.isEmpty ? nil : $0 } ?? courtText("没有找到足够的场地地标")
            return Row(id: id, title: title, value: courtText("球场映射未就绪"), detail: reason + courtText("。识别出球场前不画落点、不判界内外。"), tone: .warning)
        }
        // The in-house court says how it was found in `reason` (lines and pixel error); S家 leaves it empty.
        let found = calibration.reason.flatMap { $0.isEmpty ? nil : $0 } ?? courtFormat("自动识别 · %1$@ 个场地参考点", "\(calibration.landmarkCount)")
        var parts = [found]
        if let residual = calibration.validationErrorMeters, residual.isFinite { parts.append(courtPrintf("拟合残差 %.2f m", residual)) }
        return Row(id: id, title: title, value: courtText("球场映射可用"), detail: parts.joined(separator: " · "), tone: .good)
    }

    static func people(_ input: Input) -> Row {
        let id = "court.recognition.people", title = courtText("人员")
        guard input.isLive else { return Row(id: id, title: title, value: "—", tone: .idle) }
        if input.shed >= 1, input.inHouse {
            return Row(id: id, title: title, value: courtText("已放慢"), detail: courtFormat("机位降载：自研模型的人员检测放慢到每秒 %1$@ 次，部分击球可能认不出击球人和动作。", "\(input.shed >= 2 ? 2 : 3)"),
                       tone: .warning)
        }
        if input.shed >= 1 {
            return Row(id: id, title: title, value: courtText("已暂停"), detail: courtText("机位降载时暂停人员检测；击球、球速和落点照常分析。"), tone: .idle)
        }
        guard let people = input.people, people.streamID == input.streamID,
              let latest = input.latestPTS, latest - people.pts <= staleSeconds else {
            return Row(id: id, title: title, value: "—", detail: courtText("暂无人员检测结果。"), tone: .idle)
        }
        return Row(id: id, title: title, value: courtFormat("%1$@ 人", "\(people.count)"),
                   detail: courtText("画面里检测到的所有人，可能包括场外的人；只作辅助显示，不参与击球、球速和落点计算。"),
                   tone: people.count > 0 ? .good : .idle)
    }

    /// Shots found while the picture moved would be false flights, so none are counted then.
    static let movingDetail = courtText("画面在动，暂不记击球；机位架稳后自动继续。")

    static func shots(_ input: Input) -> Row {
        let id = "court.recognition.shots", title = courtText("击球")
        if input.isLive, input.pictureMoving {
            return Row(id: id, title: title, value: input.events.isEmpty ? courtText("尚无击球") : courtFormat("%1$@ 拍", "\(input.events.count)"),
                       detail: movingDetail, tone: .warning)
        }
        guard let last = input.events.last else {
            return Row(id: id, title: title, value: courtText("尚无击球"), detail: input.isLive ? courtText("等待第一拍。") : nil, tone: .idle)
        }
        var detail: String?
        if input.isLive, last.streamID == input.streamID, let latest = input.latestPTS, latest >= last.sourcePTS {
            detail = courtText("最近一拍 ") + Self.ago(latest - last.sourcePTS)
        }
        return Row(id: id, title: title, value: courtFormat("%1$@ 拍", "\(input.events.count)"), detail: detail, tone: input.isLive ? .good : .idle)
    }

    static func speed(_ input: Input) -> Row {
        let settled = Array(input.events.filter { $0.speedReasonKind?.isPending != true }.suffix(window))
        let missing = settled.compactMap(\.speedReasonText)
        return counted(id: "court.recognition.speed", title: courtText("球速"), settled: settled.count, missing: missing, anyShots: !input.events.isEmpty)
    }

    static func landing(_ input: Input) -> Row {
        let id = "court.recognition.landing", title = courtText("落点")
        if input.isLive, input.shed >= 2, !input.inHouse {
            return Row(id: id, title: title, value: courtText("已暂停"), detail: courtText("机位负载高，暂不定位落点；动作与球速照常。"), tone: .warning)
        }
        let settled = Array(input.events.filter { $0.placementReasonKind?.isPending != true }.suffix(window))
        let missing = settled.compactMap(\.placementReasonText)
        return counted(id: id, title: title, settled: settled.count, missing: missing, anyShots: !input.events.isEmpty)
    }

    // MARK: Helpers

    /// "found / settled 拍", and the most common reason among the shots without a value.
    private static func counted(id: String, title: String, settled: Int, missing: [String], anyShots: Bool) -> Row {
        guard settled > 0 else { return Row(id: id, title: title, value: "—", detail: anyShots ? courtText("还在分析已检出的击球。") : nil, tone: .idle) }
        let found = settled - missing.count
        let top = Dictionary(grouping: missing, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }
        let tone: Tone = found > 0 ? .good : settled >= 5 ? .warning : .idle
        return Row(id: id, title: title, value: courtFormat("%1$@ / %2$@ 拍", "\(found)", "\(settled)"),
                   detail: top.map { courtFormat("未给出的主要原因：%1$@（%2$@ 拍）", "\($0.key)", "\($0.value.count)") }, tone: tone)
    }

    static func ago(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return value < 60 ? courtFormat("%1$@ 秒前", "\(value)") : courtFormat("%1$@ 分 %2$@ 秒前", "\(value / 60)", "\(value % 60)")
    }
}
