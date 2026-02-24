import SwiftUI
import UniformTypeIdentifiers

// MARK: - RecordListView (中栏：文件记录列表)
struct RecordListView: View {
    @ObservedObject var listVM: RecordListViewModel
    @State private var showImporter = false
    @State private var showNewText = false
    @State private var newTextFilename = "text.txt"
    @State private var newTextContent = ""

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            listBody
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("导入文件")
                .keyboardShortcut("o", modifiers: .command)

                Button {
                    showNewText = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .help("新建文本记录")
            }
        }
        .sheet(isPresented: $showNewText) {
            NavigationStack {
                Form {
                    TextField("文件名", text: $newTextFilename)
                    TextEditor(text: $newTextContent)
                        .frame(minHeight: 240)
                }
                .padding(14)
                .navigationTitle("新建文本记录")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            showNewText = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") {
                            listVM.createTextRecord(text: newTextContent, filename: newTextFilename)
                            newTextFilename = "text.txt"
                            newTextContent = ""
                            showNewText = false
                        }
                        .disabled(newTextContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .frame(width: 560, height: 420)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if let urls = try? result.get() {
                listVM.importFiles(urls: urls)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNewRecord)) { _ in
            showNewText = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importFiles)) { _ in
            showImporter = true
        }
        .onAppear { listVM.loadRecords() }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索预览/文件名...", text: $listVM.filter.searchText)
                .textFieldStyle(.plain)
            if !listVM.filter.searchText.isEmpty {
                Button {
                    listVM.filter.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var listBody: some View {
        if listVM.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if listVM.records.isEmpty {
            EmptyStateView()
        } else {
            List(listVM.records, selection: $listVM.selectedRecordID) { record in
                RecordRowView(record: record)
                    .tag(record.id)
                    .contextMenu {
                        Button {
                            listVM.togglePin(record)
                        } label: {
                            Label(record.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                        }
                        Button {
                            listVM.toggleArchive(record)
                        } label: {
                            Label(record.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
                        }
                        Divider()
                        Button(role: .destructive) {
                            listVM.delete(record)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Record Row
struct RecordRowView: View {
    let record: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: record.content.fileType.icon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if record.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Text(record.content.filename)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(record.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(record.preview.isEmpty ? " " : record.preview)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Empty State
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 46))
                .foregroundColor(.secondary)
            Text("没有记录")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("导入文件或新建文本记录")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
