import Foundation
import SwiftUI

// MARK: - Tag (多级标签)
struct Tag: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var parentID: String?   // 支持层级
    var color: String       // hex color string e.g. "#FF5733"
    var icon: String        // SF Symbol name
    var createdAt: Date
    var sortOrder: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        parentID: String? = nil,
        color: String = "#007AFF",
        icon: String = "tag",
        createdAt: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.color = color
        self.icon = icon
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }

    var swiftUIColor: Color {
        Color(hex: color) ?? .blue
    }
}

// MARK: - TagTree (层级标签树节点)
struct TagTreeNode: Identifiable {
    let tag: Tag
    var children: [TagTreeNode]
    var id: String { tag.id }
    var recordCount: Int = 0
}
