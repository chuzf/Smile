import SwiftUI
import SwiftData

@main
struct SmileApp: App {
    let container: ModelContainer
    @State private var lockSession = LockSessionManager()
    @State private var shareCenter = ShareInboxCenter()

    @Environment(\.scenePhase) private var scenePhase

    init() {
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
            if phase == .background {
                Task { @MainActor in lockSession.lockAll() }
            }
        }
    }
}
