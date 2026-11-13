import SwiftUI
import CourtApp

@main struct ZacksCourtMacApp: App {
    private let languageReady: Void = CourtAppLaunch.activate()
    @State private var workspace = WorkspaceModel()
    @NSApplicationDelegateAdaptor(CourtAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Zacks Court") {
            let _ = languageReady
            CourtWorkspace(model: workspace)
                .courtLanguage()
                .frame(minWidth: 760, minHeight: 600)
                .preferredColorScheme(.dark)
                .onAppear { delegate.workspace = workspace }
                .onOpenURL { workspace.handleURL($0) }
        }
        .defaultSize(width: 1280, height: 850)
        .commands { CommandGroup(replacing: .newItem) {} }
        Window(courtText("球速测速牌"), id: "court.speedboard") {
            CourtMetricFocus(model: workspace, metric: .speed).frame(minWidth: 520, minHeight: 320)
        }.defaultSize(width: 1100, height: 700)
        Window(courtText("落点看板"), id: "court.placement") {
            CourtMetricFocus(model: workspace, metric: .placement).frame(minWidth: 440, minHeight: 500)
        }.defaultSize(width: 600, height: 760)
        Window(courtText("实时画面"), id: "court.live-video") {
            CourtLiveVideoWindow(model: workspace).frame(minWidth: 640, minHeight: 420)
        }.defaultSize(width: 1000, height: 650)
    }
}

@MainActor final class CourtAppDelegate: NSObject, NSApplicationDelegate {
    var workspace: WorkspaceModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        Task {
            await workspace.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
