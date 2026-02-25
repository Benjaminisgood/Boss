import SwiftUI

enum WorkspaceSection: Hashable {
    case records
    case assistant
}

// MARK: - ContentView (主窗口三栏布局)
struct ContentView: View {
    @StateObject private var listVM = RecordListViewModel()
    @StateObject private var assistantState = AssistantWorkspaceState()
    @State private var workspaceSection: WorkspaceSection = .records

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(listVM: listVM, workspaceSection: $workspaceSection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            switch workspaceSection {
            case .records:
                RecordListView(listVM: listVM)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
            case .assistant:
                AssistantInputColumnView(state: assistantState)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 420, max: 520)
            }
        } detail: {
            switch workspaceSection {
            case .records:
                RecordDetailView(recordID: listVM.selectedRecordID)
            case .assistant:
                AssistantOutputColumnView(state: assistantState)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .navigationTitle("Boss")
        .frame(minWidth: 800, minHeight: 500)
    }
}
