import SwiftUI
import CourtCore

@MainActor
struct CourtCalibrationSheet: View {
    let model: WorkspaceModel
    private let frozenFrame: CGImage?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var corners: [NormalizedPoint]
    /// The finger while pressing on the picture (container coordinates); shows the loupe.
    @State private var touch: CGPoint?
    /// The placed corner being dragged, if the press started on one.
    @State private var dragging: Int?
    private let labels = ["近端左角", "近端右角", "远端右角", "远端左角"]

    init(model: WorkspaceModel) {
        self.model = model
        frozenFrame = model.calibrationFrame
        _corners = State(initialValue: model.manualCourtCorners ?? [])
    }

    private var frameValid: Bool { model.isLive && frozenFrame != nil && model.calibrationFrame === frozenFrame }
    var body: some View {
        NavigationStack {
            GeometryReader { outer in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("标出球场的四个外角").font(.title2.weight(.semibold))
                            // At accessibility sizes this runs several screens; the picture comes first.
                            if !dynamicTypeSize.isAccessibilitySize { instructions }
                        }
                        // The step sits right above the picture so both are in view while placing points.
                        if corners.count < 4 {
                            Label("下一点：\(corners.count + 1) · \(labels[corners.count])", systemImage: "scope")
                                .font(.headline).foregroundStyle(CourtStyle.green)
                        } else {
                            Label("四角已选，请核对边线是否对齐", systemImage: "checkmark.circle")
                                .font(.headline).foregroundStyle(CourtStyle.green)
                        }
                        if let frozenFrame {
                            // As large as the window allows: width-limited on a portrait phone, height-limited
                            // in landscape and on a Mac, keeping the step above it in view.
                            calibrationImage(frozenFrame)
                                .frame(maxHeight: max(200, outer.size.height - 110))
                                .aspectRatio(Double(frozenFrame.width) / Double(max(1, frozenFrame.height)), contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        } else { CourtNotice(text: "没有可用的冻结画面。请返回并确认机位正在采集。", warning: true) }
                        if !frameValid { CourtNotice(text: "画面来源已变化或连接已中断。请返回重新获取标定画面。", warning: true) }
                        if dynamicTypeSize.isAccessibilitySize { instructions }
                        CourtMetricGrid {
                            ForEach(0..<4, id: \.self) { index in
                                HStack(spacing: 8) {
                                    Text("\(index + 1)").font(.caption.monospaced().bold())
                                        .frame(width: 24, height: 24).background(index < corners.count ? CourtStyle.green.opacity(0.2) : CourtStyle.raised, in: Circle())
                                    Text(labels[index]).font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { undoButton; resetButton }
                            VStack(alignment: .leading, spacing: 10) { undoButton; resetButton }
                        }
                        Button {
                            if model.setManualCourtCorners(corners) { dismiss() }
                        } label: { Label("保存球场四角", systemImage: "checkmark").frame(maxWidth: .infinity) }
                            .buttonStyle(CourtButton(primary: true))
                            .disabled(corners.count != 4 || !frameValid)
                            .accessibilityIdentifier("court.calibration.save")
                        if model.manualCourtCorners != nil {
                            Button {
                                if model.setManualCourtCorners(nil) { dismiss() }
                            } label: { Label("移除手工四角，使用自动识别", systemImage: "arrow.uturn.backward") }
                                .buttonStyle(CourtButton()).disabled(!frameValid)
                        }
                        if let error = model.error { CourtErrorBanner(text: error) { model.error = nil } }
                        CourtNotice(text: "手工四角提供地面映射参考，不能单独证明球速或落点的物理精度。点击顺序或角点位置不正确时，分析仍可能拒绝映射。移动镜头、改变倍率或切换视频源后需重新标定。")
                    }.padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
                }
                .scrollDisabled(touch != nil)
                .accessibilityIdentifier("court.calibration.scroll")
            }
            .background(CourtStyle.background)
            .navigationTitle("标定球场")
            .toolbar { ToolbarItem(placement: .cancellationAction) { CourtTextButton("取消") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(CourtStyle.green)
            #if os(macOS)
            .frame(minWidth: 640, idealWidth: 900, minHeight: 650)
            #endif
    }

    private var instructions: some View {
        Text("使用已冻结的真实画面，按顺序点双打场地的四个外角。近端指靠近机位的底线。按住画面会出现放大镜，松手前可移动对准；已放的点可以拖动微调。")
            .font(.callout).foregroundStyle(CourtStyle.muted).fixedSize(horizontal: false, vertical: true)
    }

    private var undoButton: some View {
        Button { if !corners.isEmpty { corners.removeLast() } } label: { Label("撤销上一点", systemImage: "arrow.uturn.backward") }
            .buttonStyle(CourtButton()).disabled(corners.isEmpty)
    }
    private var resetButton: some View {
        Button { corners.removeAll() } label: { Label("重新选点", systemImage: "arrow.clockwise") }
            .buttonStyle(CourtButton()).disabled(corners.isEmpty)
    }

    private func calibrationImage(_ frame: CGImage) -> some View {
        GeometryReader { geometry in
            let rect = Self.imageRect(imageWidth: Double(frame.width), imageHeight: Double(frame.height), container: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(decorative: frame, scale: 1).resizable().interpolation(.high)
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                Canvas { context, _ in
                    let positions = corners.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
                    if positions.count > 1 {
                        var outline = Path(); outline.addLines(positions)
                        if positions.count == 4 { outline.closeSubpath() }
                        context.stroke(outline, with: .color(CourtStyle.green), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                    // A ring with a center dot leaves the corner itself visible; the number sits beside it.
                    for (index, point) in positions.enumerated() {
                        Self.drawCorner(index + 1, at: point, active: dragging == index, in: &context)
                    }
                    if let touch, dragging == nil, corners.count < 4 {
                        Self.drawCorner(corners.count + 1, at: touch, active: true, in: &context)
                    }
                }.allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: CourtStyle.Radius.card))
            .overlay {
                if let touch { loupe(frame, rect: rect, at: touch, container: geometry.size) }
            }
            // Only the picture (plus a margin for corners on its edge) takes touches, so the letterbox
            // beside it still scrolls the page.
            .contentShape(Path(rect.insetBy(dx: -16, dy: -16)))
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard frameValid else { return }
                if touch == nil { dragging = nearestCorner(to: value.startLocation, rect: rect) }
                let point = Self.clamp(value.location, to: rect)
                touch = point
                if let dragging, corners.indices.contains(dragging) {
                    corners[dragging] = NormalizedPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
                }
            }.onEnded { value in
                defer { touch = nil; dragging = nil }
                guard frameValid, dragging == nil, corners.count < 4, rect.width > 0, rect.height > 0,
                      rect.insetBy(dx: -16, dy: -16).contains(value.location) else { return }
                let point = Self.clamp(value.location, to: rect)
                corners.append(NormalizedPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height))
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("冻结球场画面，按近端左、近端右、远端右、远端左顺序选四角")
        .accessibilityValue("已选 \(corners.count) 个角")
        .accessibilityHint("标定需要看着画面点选四个角，读屏无法完成。不标定时分析会自动识别球场。")
        .accessibilityIdentifier("court.calibration.image")
    }

    private static func drawCorner(_ number: Int, at point: CGPoint, active: Bool, in context: inout GraphicsContext) {
        let ring = Path(ellipseIn: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))
        context.stroke(ring, with: .color(.black.opacity(0.6)), lineWidth: 4)
        context.stroke(ring, with: .color(active ? .white : CourtStyle.green), lineWidth: 2)
        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(CourtStyle.green))
        let badge = CGPoint(x: point.x + 18, y: point.y - 18)
        context.fill(Path(ellipseIn: CGRect(x: badge.x - 10, y: badge.y - 10, width: 20, height: 20)), with: .color(CourtStyle.green))
        context.draw(Text("\(number)").font(.caption2.bold()).foregroundColor(.black), at: badge)
    }

    /// A 3× magnifier with a crosshair on the point under the finger. It sits above the finger, or
    /// beside it when there is no room, so the finger never covers what it shows.
    private func loupe(_ frame: CGImage, rect: CGRect, at touch: CGPoint, container: CGSize) -> some View {
        let diameter: CGFloat = 120, zoom: CGFloat = 3, gap: CGFloat = 30
        let local = CGPoint(x: (touch.x - rect.minX) * zoom, y: (touch.y - rect.minY) * zoom)
        var center = CGPoint(x: touch.x, y: touch.y - diameter / 2 - gap)
        if center.y - diameter / 2 < 0 {
            let below = touch.y + diameter / 2 + gap
            if below + diameter / 2 <= container.height {
                center.y = below
            } else {
                center.y = min(max(touch.y, diameter / 2), max(diameter / 2, container.height - diameter / 2))
                center.x = touch.x > container.width / 2 ? touch.x - diameter / 2 - gap : touch.x + diameter / 2 + gap
            }
        }
        center.x = min(max(center.x, diameter / 2), max(diameter / 2, container.width - diameter / 2))
        return ZStack {
            Color.black
            Image(decorative: frame, scale: 1).resizable().interpolation(.high)
                .frame(width: rect.width * zoom, height: rect.height * zoom)
                .offset(x: diameter / 2 - local.x, y: diameter / 2 - local.y)
                .frame(width: diameter, height: diameter, alignment: .topLeading)
            Canvas { context, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                var cross = Path()
                for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                    cross.move(to: CGPoint(x: c.x + dx * 5, y: c.y + dy * 5))
                    cross.addLine(to: CGPoint(x: c.x + dx * 18, y: c.y + dy * 18))
                }
                context.stroke(cross, with: .color(.black.opacity(0.7)), lineWidth: 3.5)
                context.stroke(cross, with: .color(CourtStyle.green), lineWidth: 1.5)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(CourtStyle.green, lineWidth: 2))
        .shadow(color: .black.opacity(0.5), radius: 6)
        .position(center)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A placed corner within reach of the press, so it is moved instead of adding a new point.
    private func nearestCorner(to location: CGPoint, rect: CGRect) -> Int? {
        corners.indices
            .map { ($0, hypot(rect.minX + corners[$0].x * rect.width - location.x, rect.minY + corners[$0].y * rect.height - location.y)) }
            .filter { $0.1 <= 28 }
            .min { $0.1 < $1.1 }?.0
    }

    static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    /// Matches the image's aspect-fit rect, excluding every letterbox margin.
    static func imageRect(imageWidth: Double, imageHeight: Double, container: CGSize) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageWidth, container.height / imageHeight)
        let size = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    static func normalizedPoint(at location: CGPoint, imageWidth: Double, imageHeight: Double, container: CGSize) -> NormalizedPoint? {
        let rect = imageRect(imageWidth: imageWidth, imageHeight: imageHeight, container: container)
        guard rect.width > 0, rect.height > 0, rect.contains(location) else { return nil }
        return NormalizedPoint(x: (location.x - rect.minX) / rect.width, y: (location.y - rect.minY) / rect.height)
    }
}
