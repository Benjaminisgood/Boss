import SwiftUI

// MARK: - ContentView (主窗口三栏布局)
struct ContentView: View {
    @StateObject private var listVM = RecordListViewModel()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(listVM: listVM)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            RecordListView(listVM: listVM)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            RecordDetailView(recordID: listVM.selectedRecordID)
        }
        .navigationTitle("Boss")
        .frame(minWidth: 800, minHeight: 500)
    }
}
