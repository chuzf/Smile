import SwiftUI
import SwiftData

@main
struct SmileApp: App {
    let container: ModelContainer

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
        }
        .modelContainer(container)
    }
}
