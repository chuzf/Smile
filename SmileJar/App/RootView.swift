import SwiftUI

struct RootView: View {
    @State private var showEntryEditor = false
    @State private var selectedTab = 0
    @State private var groupNav: GroupNavigation?
    @State private var pendingGroupID: UUID?
    @State private var pendingEntryID: UUID?

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(externalNav: $groupNav)
                .tabItem { Label("罐", systemImage: "drop.circle") }
                .tag(0)

            Color.clear
                .tabItem { Label("", systemImage: "plus.circle.fill") }
                .onAppear { showEntryEditor = true }
                .tag(1)

            MeTabView()
                .tabItem { Label("我", systemImage: "person.circle") }
                .tag(2)
        }
        .tint(AppColors.warmOrange)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showEntryEditor, onDismiss: handleEditorDismiss) {
            EntryEditorView(onSaved: { groupID, entryID in
                pendingGroupID = groupID
                pendingEntryID = entryID
                selectedTab = 0   // switch before dismiss so HomeView shows under the sheet
            })
        }
    }

    private func handleEditorDismiss() {
        guard let gid = pendingGroupID, let eid = pendingEntryID else { return }
        pendingGroupID = nil
        pendingEntryID = nil
        selectedTab = 0
        groupNav = GroupNavigation(groupID: gid, highlightEntryID: eid)
    }
}
