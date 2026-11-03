import SwiftUI
import CourtCore

/// Zoom like the system camera: tap a lens preset, or drag sideways on the presets for stepless
/// zoom on a dial (pinching the picture works too). The chip for the range the current factor is in
/// shows the exact factor. Locked while a session records, so one recording keeps one framing.
@MainActor
struct CameraZoomControl: View {
    let camera: CameraModel
    /// Points of drag per doubling of the zoom factor.
    static let pointsPerDoubling = 90.0
    @State private var dragStart: Double?

    var body: some View {
        if let range = camera.zoomRange, camera.showsZoom {
            chips(range)
            .frame(minHeight: 44)
            .background(CourtStyle.scrim, in: Capsule())
            // The dial floats above the presets so the layout around them never changes mid-drag.
            .overlay(alignment: .bottomTrailing) {
                if dragStart != nil {
                    dial(range).fixedSize()
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: CourtStyle.Radius.control))
                        .offset(y: -52).allowsHitTesting(false)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            // Drag left to zoom in, as on the system camera's dial; taps still reach the presets.
            .highPriorityGesture(DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard camera.canZoom else { return }
                    if dragStart == nil { dragStart = camera.zoomFactor }
                    camera.previewZoom(range.stepped(dragStart ?? camera.zoomFactor, by: -value.translation.width / Self.pointsPerDoubling))
                }
                .onEnded { value in
                    if let start = dragStart { camera.commitZoom(range.stepped(start, by: -value.translation.width / Self.pointsPerDoubling)) }
                    dragStart = nil
                }, including: camera.canZoom ? .all : .subviews)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("镜头倍率")
            .accessibilityValue(CameraZoomRange.title(camera.zoomFactor) + (camera.zoomLocked ? "，记录中已锁定" : ""))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: camera.commitZoom(range.stepped(camera.zoomFactor, by: 0.25))
                case .decrement: camera.commitZoom(range.stepped(camera.zoomFactor, by: -0.25))
                @unknown default: break
                }
            }
            .accessibilityIdentifier("court.camera.zoom")
        }
    }

    private func chips(_ range: CameraZoomRange) -> some View {
        HStack(spacing: 2) {
            if camera.zoomLocked {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(CourtStyle.muted)
                    .frame(width: 22, height: 44).accessibilityHidden(true)
            }
            ForEach(range.presets, id: \.self) { preset in chip(preset, range: range) }
        }.padding(.horizontal, 4)
    }

    private func chip(_ preset: Double, range: CameraZoomRange) -> some View {
        let active = range.presets.last(where: { $0 <= camera.zoomFactor + 0.001 }) == preset
        let upscaled = active && range.isUpscaled(camera.zoomFactor)
        let name = String(CameraZoomRange.title(preset).dropLast())
        return Button { camera.commitZoom(preset) } label: {
            Text(active ? CameraZoomRange.title(camera.zoomFactor) : name)
                .font(.caption.monospacedDigit().weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(active ? (upscaled ? CourtStyle.warning : CourtStyle.green) : .white)
                .frame(minWidth: 44, minHeight: 44)
                .background(active ? CourtStyle.segmentSelected : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!camera.canZoom)
        .accessibilityLabel(CameraZoomRange.title(preset))
        .accessibilityValue(upscaled ? "数码放大，画面变软" : "")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("court.camera.zoom.\(name)")
    }

    /// While dragging, above the presets: a log-scale ruler centred on the current factor, with the lens presets
    /// labelled, and the exact factor above the centre mark.
    private func dial(_ range: CameraZoomRange) -> some View {
        let current = camera.zoomFactor
        return VStack(spacing: 2) {
            Text(CameraZoomRange.title(current)).font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(range.isUpscaled(current) ? CourtStyle.warning : CourtStyle.green)
            Canvas { context, size in
                let center = size.width / 2
                let x = { (value: Double) in center + (log2(value) - log2(current)) * Self.pointsPerDoubling }
                // A tick every tenth of a doubling across the range; presets get a longer, labelled tick.
                var step = log2(range.minimum)
                while step <= log2(range.maximum) + 0.001 {
                    let position = x(pow(2, step))
                    if position >= 0, position <= size.width {
                        context.fill(Path(CGRect(x: position - 0.5, y: 4, width: 1, height: 6)), with: .color(.white.opacity(0.5)))
                    }
                    step += 0.1
                }
                for preset in range.presets {
                    let position = x(preset)
                    guard position >= 0, position <= size.width else { continue }
                    context.fill(Path(CGRect(x: position - 1, y: 2, width: 2, height: 10)), with: .color(.white))
                    context.draw(Text(String(CameraZoomRange.title(preset).dropLast())).font(.caption2.monospacedDigit()).foregroundStyle(.white),
                                 at: CGPoint(x: position, y: 20))
                }
                context.fill(Path(CGRect(x: center - 1, y: 0, width: 2, height: 14)), with: .color(CourtStyle.green))
            }
            .frame(width: 240, height: 28)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
