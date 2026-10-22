import SwiftUI
import SwiftData

@main
struct SmileApp: App {
    let container: ModelContainer
    @State private var lockSession: LockSessionManager
    @State private var shareCenter = ShareInboxCenter()
    private let privacyShield: PrivacyShieldWindow

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let lockSession = LockSessionManager()
        let shield = PrivacyShieldWindow(lockSession: lockSession)
        lockSession.onShieldChange = { shield.update(visible: $0) }
        _lockSession = State(initialValue: lockSession)
        privacyShield = shield

        do {
            let container = try ModelContainerFactory.makeShared()
            self.container = container
            Task { @MainActor in
                ModelContainerFactory.seedIfNeeded(context: container.mainContext)
            }
        } catch {
            fatalError("ModelContainer init 失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(lockSession)
                .environment(shareCenter)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // 同步处理：遮罩必须在系统截多任务快照之前盖上
            switch phase {
            case .inactive: lockSession.sceneWillResignActive()
            case .background: lockSession.sceneDidEnterBackground()
            case .active: lockSession.sceneDidBecomeActive()
            @unknown default: break
            }
        }
    }
}
