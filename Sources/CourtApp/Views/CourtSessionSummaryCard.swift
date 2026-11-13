import SwiftUI
import CourtCore

/// What the record that just finished left behind: name, length, shots, the top and average speed
/// estimates and the stroke mix, read from the saved session. Shown at the top of the display and
/// on the camera's 记录 page right after 结束, until closed or another record starts.
struct CourtSessionSummaryCard: View {
    let summary: CourtSessionSummary
    let viewDetails: () -> Void
    let dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: CourtStyle.Space.m) {
            HStack(alignment: .center, spacing: CourtStyle.Space.s) {
                Label(courtText("记录已保存"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(CourtStyle.green)
                    .accessibilityIdentifier("court.summary.saved")
                Spacer(minLength: CourtStyle.Space.s)
                Button(action: dismiss) {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(CourtStyle.muted)
                    .accessibilityLabel(courtText("关闭记录总结"))
                    .accessibilityIdentifier("court.summary.close")
            }
            .padding(.vertical, -CourtStyle.Space.s)
            HStack(alignment: .firstTextBaseline, spacing: CourtStyle.Space.m) {
                Text(summary.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CourtStyle.Space.s)
                Text(courtDuration(summary.duration)).font(.callout.monospacedDigit()).foregroundStyle(CourtStyle.muted)
                    .accessibilityLabel(courtText("时长 ") + courtDuration(summary.duration))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 220 : 96), spacing: CourtStyle.Space.s)],
                      spacing: CourtStyle.Space.s) {
                CourtMetric(title: courtText("击球"), value: summary.shotCount.map(String.init) ?? "—", unit: courtText("拍"))
                CourtMetric(title: courtText("最高"), value: courtSpeed(summary.maximumSpeed), unit: "km/h")
                CourtMetric(title: courtText("平均"), value: courtSpeed(summary.averageSpeed), unit: "km/h")
            }
            Text(caption).font(.caption).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
            if !summary.strokes.isEmpty { strokes }
            Button(action: viewDetails) {
                Label(courtText("查看详情"), systemImage: "chart.xyaxis.line").frame(maxWidth: .infinity)
            }.buttonStyle(CourtButton())
                .accessibilityIdentifier("court.summary.details")
        }
        .padding(CourtStyle.Space.l)
        .background(CourtStyle.panel, in: RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: CourtStyle.Radius.card).strokeBorder(CourtStyle.selectedStroke))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("court.summary")
    }

    /// Where the numbers come from, and what is missing; never a 0 standing in for unknown.
    private var caption: String {
        var parts: [String]
        switch summary.shotCount {
        case nil: parts = [courtText("没有逐拍分析结果")]
        case 0: parts = [courtText("没有识别到击球候选")]
        case let shots?: parts = [courtFormat("%1$@ / %2$@ 拍有球速 · 模型估算", "\(summary.speedCount)", "\(shots)")]
        }
        if summary.markerCount > 0 { parts.append(courtFormat("标记 %1$@ 个时刻", "\(summary.markerCount)")) }
        return parts.joined(separator: " · ")
    }

    /// Stroke mix: one thin stacked bar (length repeats the counts) and labelled counts below it.
    private var strokes: some View {
        let total = max(1, summary.strokes.reduce(0) { $0 + $1.count })
        return VStack(alignment: .leading, spacing: CourtStyle.Space.s) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(summary.strokes, id: \.kind) { item in
                        Rectangle().fill(item.kind.courtColor)
                            .frame(width: max(2, (geometry.size.width - Double(summary.strokes.count - 1) * 2) * Double(item.count) / Double(total)))
                    }
                }
            }
            .frame(height: 6).clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 200 : 110), spacing: CourtStyle.Space.s, alignment: .leading)],
                      alignment: .leading, spacing: CourtStyle.Space.xs) {
                ForEach(summary.strokes, id: \.kind) { item in
                    HStack(spacing: CourtStyle.Space.xs) {
                        CourtStrokeTag(kind: item.kind, font: .caption)
                        Text("\(item.count)").font(.caption.monospacedDigit()).foregroundStyle(CourtStyle.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(courtText("动作分布"))
        .accessibilityIdentifier("court.summary.strokes")
    }
}
