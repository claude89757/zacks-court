import SwiftUI
import CourtApp
import UIKit
import OSLog

@main struct ZacksCourtApp: App {
    // Before any model init, so the first screen already uses the system language.
    private let languageReady: Void = CourtAppLaunch.activate()
    @UIApplicationDelegateAdaptor(CourtOrientationDelegate.self) private var orientation
    // Developer-only feasibility measurement, opted in through the launch environment. It must not
    // create WorkspaceModel: that model's 1 Hz tick re-enables the idle timer and the screen would lock.
    private let phase0 = Phase0Options.requested
    var body: some Scene {
        WindowGroup {
            let _ = languageReady
            if let phase0 { Phase0Root(options: phase0) } else { WorkspaceRoot(orientation: orientation) }
        }
    }
}

private struct WorkspaceRoot: View {
    let orientation: CourtOrientationDelegate
    // A developer autopilot run keeps its sessions apart from the user's own history.
    @State private var workspace = WorkspaceModel(storageDirectory: CameraAutopilot.requested?.storage)
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        CourtWorkspace(model: workspace)
            .courtLanguage()
            .preferredColorScheme(.dark)
            .onOpenURL { workspace.handleURL($0) }
            .task { if let autopilot = CameraAutopilot.requested { await autopilot.start(workspace) } }
            .onAppear { orientation.update(cameraMode: workspace.role == .camera) }
            .onChange(of: workspace.role) { _, role in orientation.update(cameraMode: role == .camera) }
            .onChange(of: scenePhase) { _, phase in
                workspace.setSceneActive(phase == .active)
                if phase == .background { Task { await workspace.setForeground(false) } }
                else if phase == .active {
                    orientation.update(cameraMode: workspace.role == .camera)
                    Task { await workspace.setForeground(true) }
                }
            }
    }
}

@MainActor
final class CourtOrientationDelegate: NSObject, UIApplicationDelegate {
    private var cameraMode = false
    private var previousOrientation: UIInterfaceOrientation = .portrait
    private var mask: UIInterfaceOrientationMask = .allButUpsideDown
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { mask }
    func update(cameraMode: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else {
            mask = cameraMode ? .landscape : .allButUpsideDown
            return
        }
        let entering = cameraMode && !self.cameraMode
        let leaving = !cameraMode && self.cameraMode
        if entering, scene.interfaceOrientation != .unknown { previousOrientation = scene.interfaceOrientation }
        self.cameraMode = cameraMode
        mask = cameraMode ? .landscape : .allButUpsideDown
        let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        root?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let requested: UIInterfaceOrientationMask
        if cameraMode {
            guard !scene.interfaceOrientation.isLandscape else { return }
            requested = .landscape
        } else if leaving {
            switch previousOrientation {
            case .landscapeLeft: requested = .landscapeLeft
            case .landscapeRight: requested = .landscapeRight
            default: requested = .portrait
            }
        } else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: requested)) { error in
            Logger(subsystem: "com.claude89757.zackscourt", category: "orientation")
                .error("Orientation request failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
