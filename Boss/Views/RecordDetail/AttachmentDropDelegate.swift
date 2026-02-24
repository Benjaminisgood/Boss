import SwiftUI
import UniformTypeIdentifiers

// MARK: - AttachmentDropDelegate (处理附件拖拽)
class AttachmentDropDelegate: DropDelegate {
    private let vm: RecordDetailViewModel
    
    init(vm: RecordDetailViewModel) {
        self.vm = vm
    }
    
    func dropEntered(info: DropInfo) {
        // 可以在这里添加视觉反馈
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .copy)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        guard let itemProvider = info.itemProviders(for: [.fileURL]).first else {
            return false
        }
        
        itemProvider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { [weak self] (data, error) in
            guard let data = data as? Data, 
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  let self = self else {
                return
            }
            
            Task {
                await MainActor.run {
                    self.vm.replaceFile(url: url)
                }
            }
        }
        
        return true
    }
    
    func dropExited(info: DropInfo) {
        // 可以在这里移除视觉反馈
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        return true
    }
}
