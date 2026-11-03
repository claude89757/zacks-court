import SwiftUI
import CourtCore

@MainActor
struct CourtHandednessSheet: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var near: TennisHandedness
    @State private var far: TennisHandedness

    init(model: WorkspaceModel) {
        self.model = model
        _near = State(initialValue: model.nearHandedness)
        _far = State(initialValue: model.farHandedness)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("确认画面两侧的持拍手").font(.title2.weight(.semibold))
                    CourtNotice(text: "近端指靠近机位的一侧，远端指另一侧。设置只对应当前场侧，不会自动识别或持续追踪球员身份。")
                    handPicker("近端持拍手", selection: $near)
                    handPicker("远端持拍手", selection: $far)
                    CourtNotice(text: "近端、远端默认均为右手，左手球员请单独修改。选择「未知」时显示「落地击球」。换边后请重新设置；双打同侧无法对应唯一球员时，请选择「未知」。")
                    Button {
                        model.setHandedness(near: near, far: far)
                        dismiss()
                    } label: { Label("保存持拍手", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .buttonStyle(CourtButton(primary: true))
                    CourtNotice(text: "设置影响之后的击球分类，不改写已保存的记录。")
                }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("court.handedness.scroll").background(CourtStyle.background)
                .navigationTitle("持拍手")
                .toolbar { ToolbarItem(placement: .cancellationAction) { CourtTextButton("取消") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(CourtStyle.green)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 540)
            #endif
    }

    private func handPicker(_ title: String, selection: Binding<TennisHandedness>) -> some View {
        CourtPanel(title) {
            Picker(title, selection: selection) {
                Text("未知").tag(TennisHandedness.unknown)
                Text("右手").tag(TennisHandedness.right)
                Text("左手").tag(TennisHandedness.left)
            }.pickerStyle(.menu).frame(minHeight: 44)
        }
    }
}
