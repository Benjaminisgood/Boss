import SwiftUI

// MARK: - TagEditorView (标签创建/编辑视图)
struct TagEditorView: View {
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var parentID: String? = nil
    @State private var color: String = "#007AFF"
    @State private var icon: String = "tag"
    
    let allTags: [Tag]
    let onSave: (Tag) -> Void
    let existingTag: Tag?
    
    init(isPresented: Binding<Bool>, allTags: [Tag] = [], existingTag: Tag? = nil, onSave: @escaping (Tag) -> Void) {
        self._isPresented = isPresented
        self.allTags = allTags
        self.existingTag = existingTag
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("标签名称", text: $name)
                        .font(.system(size: 14))
                    
                    Picker("父标签", selection: $parentID) {
                        Text("无").tag(Optional<String>.none)
                        ForEach(availableParentTags) { tag in
                            Text(tag.name).tag(Optional(tag.id))
                        }
                    }
                    .font(.system(size: 14))
                }
                
                Section("外观") {
                    Picker("图标", selection: $icon) {
                        ForEach(availableIcons, id: \.self) {
                            Label($0, systemImage: $0)
                        }
                    }
                    .font(.system(size: 14))
                    
                    ColorPicker("颜色", selection: Binding(
                        get: { Color(hex: color) ?? .blue },
                        set: { color = $0.hexString }
                    ))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existingTag == nil ? "新建标签" : "编辑标签")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveTag()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(width: 400, height: 400)
        .onAppear {
            guard let existingTag else { return }
            name = existingTag.name
            parentID = existingTag.parentID
            color = existingTag.color
            icon = existingTag.icon
        }
    }
    
    private var availableParentTags: [Tag] {
        allTags.filter { $0.id != existingTag?.id }
    }
    
    private var availableIcons: [String] {
        ["tag", "folder", "folder.badge.plus", "star", "heart", "flag", "circle", "square", "diamond"]
    }
    
    private func saveTag() {
        let tag = Tag(
            id: existingTag?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            parentID: parentID,
            color: color,
            icon: icon,
            createdAt: existingTag?.createdAt ?? Date(),
            sortOrder: existingTag?.sortOrder ?? 0
        )
        
        onSave(tag)
        isPresented = false
    }
}
