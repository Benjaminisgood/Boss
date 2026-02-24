import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - RecordDetailView (右侧详情：一条记录=一个文件)
struct RecordDetailView: View {
    @StateObject private var vm = RecordDetailViewModel()
    let recordID: String?

    var body: some View {
        Group {
            if let record = vm.record {
                FileRecordDetailView(vm: vm, record: record)
            } else {
                noSelectionView
            }
        }
        .onChange(of: recordID) { id in vm.load(id: id) }
        .onAppear { vm.load(id: recordID) }
    }

    private var noSelectionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("选择或导入一个文件记录")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileRecordDetailView: View {
    @ObservedObject var vm: RecordDetailViewModel
    let record: Record
    @State private var showTagPicker = false
    @State private var showReplaceImporter = false

    private var fileURL: URL {
        FileStorageService.shared.absoluteURL(for: record.content.filePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            contentBody
        }
        .onDrop(of: [.fileURL], delegate: AttachmentDropDelegate(vm: vm))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("打开文件")

                Button {
                    showReplaceImporter = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("替换文件")

                if vm.canEditTextContent {
                    Button {
                        vm.saveNow()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(!vm.isDirty)
                    .help("保存文本")
                }
            }
        }
        .fileImporter(isPresented: $showReplaceImporter, allowedContentTypes: [.item]) { result in
            if let url = try? result.get() {
                vm.replaceFile(url: url)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: record.content.fileType.icon)
                    .foregroundColor(.secondary)
                Text(record.content.filename)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if vm.isSaving {
                    ProgressView().controlSize(.small)
                } else if vm.isDirty {
                    Text("未保存")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            HStack(spacing: 12) {
                Label(record.content.fileType.displayName, systemImage: record.content.fileType.icon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(record.content.contentType)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.content.sizeBytes), countStyle: .file))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(record.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Picker("可见性", selection: Binding(
                    get: { vm.record?.visibility ?? .private },
                    set: { vm.updateVisibility($0) }
                )) {
                    Text("私有").tag(Record.Visibility.private)
                    Text("公开").tag(Record.Visibility.public)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button {
                    showTagPicker.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                        Text(record.tags.isEmpty ? "标签" : "\(record.tags.count) 个标签")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showTagPicker) {
                    TagPickerView(allTags: vm.allTags, selectedIDs: record.tags) { tagID in
                        vm.toggleTag(tagID)
                    }
                }

                Spacer()
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var contentBody: some View {
        if vm.canEditTextContent {
            TextEditor(text: Binding(
                get: { vm.textContent },
                set: { vm.updateTextContent($0) }
            ))
            .font(.body.monospaced())
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if record.content.fileType == .image, let image = NSImage(contentsOf: fileURL) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                Image(systemName: record.content.fileType.icon)
                    .font(.system(size: 50))
                    .foregroundColor(.secondary)
                Text("该类型不在应用内直接预览")
                    .foregroundColor(.secondary)
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Tag Picker Popover
struct TagPickerView: View {
    let allTags: [Tag]
    let selectedIDs: [String]
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选择标签").font(.headline).padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allTags) { tag in
                        HStack {
                            Image(systemName: selectedIDs.contains(tag.id) ? "checkmark.square.fill" : "square")
                                .foregroundColor(tag.swiftUIColor)
                            Image(systemName: tag.icon).foregroundColor(tag.swiftUIColor)
                            Text(tag.name)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { onToggle(tag.id) }
                    }
                }
            }
        }
        .frame(width: 240, height: 320)
    }
}
