import SwiftUI

/// The 「识别状态」 rows: a symbol and color per state (never color alone), title, value and a
/// one-line reason. Stacks vertically at accessibility sizes so values never wrap per character.
struct RecognitionRows: View {
    let status: RecognitionStatus
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text("识别状态").font(.caption.weight(.semibold)).foregroundStyle(CourtStyle.muted)
            ForEach(status.rows) { row in rowView(row) }
            Text("按最近 \(RecognitionStatus.window) 拍统计；还在等待结果的拍不计入。")
                .font(.caption2).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityIdentifier("court.recognition")
    }

    private func rowView(_ row: RecognitionStatus.Row) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The value text already names the state for VoiceOver.
            Image(systemName: symbol(row.tone)).foregroundStyle(color(row.tone)).font(.caption).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                layout {
                    Text(row.title).font(.caption).foregroundStyle(CourtStyle.muted)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                    Text(row.value).font((compact ? Font.caption : .callout).weight(.medium).monospacedDigit())
                        .foregroundStyle(row.tone == .warning ? CourtStyle.warning : .primary)
                }
                if let detail = row.detail {
                    Text(detail).font(.caption2).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        // Children stay separate elements so UI tests can find the value text (for example 「球场映射可用」).
        }.accessibilityElement(children: .contain).accessibilityIdentifier(row.id)
    }

    private func symbol(_ tone: RecognitionStatus.Tone) -> String {
        switch tone { case .good: return "checkmark.circle.fill"; case .idle: return "circle.dashed"; case .warning: return "exclamationmark.triangle.fill" }
    }
    private func color(_ tone: RecognitionStatus.Tone) -> Color {
        switch tone { case .good: return CourtStyle.green; case .idle: return CourtStyle.muted; case .warning: return CourtStyle.warning }
    }
}
