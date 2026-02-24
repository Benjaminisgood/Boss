import Foundation

// MARK: - Record (对齐 Benoss: 一条记录绑定一个内容文件/文本)
struct Record: Identifiable, Codable, Hashable {
    enum Visibility: String, Codable, CaseIterable {
        case `public`
        case `private`
    }

    enum ContentKind: String, Codable {
        case text
        case file
    }

    enum FileType: String, Codable, CaseIterable {
        case text
        case web
        case image
        case video
        case audio
        case log
        case database
        case archive
        case document
        case file

        var isTextLike: Bool {
            switch self {
            case .text, .web, .log:
                return true
            default:
                return false
            }
        }
    }

    struct Content: Codable, Hashable {
        var kind: ContentKind
        var fileType: FileType
        var textPreview: String
        var filePath: String
        var filename: String
        var contentType: String
        var sizeBytes: Int
        var sha256: String

        init(
            kind: ContentKind,
            fileType: FileType,
            textPreview: String = "",
            filePath: String,
            filename: String,
            contentType: String = "application/octet-stream",
            sizeBytes: Int = 0,
            sha256: String = ""
        ) {
            self.kind = kind
            self.fileType = fileType
            self.textPreview = textPreview
            self.filePath = filePath
            self.filename = filename
            self.contentType = contentType
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
        }
    }

    var id: String
    var visibility: Visibility
    var preview: String
    var content: Content
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var isArchived: Bool

    init(
        id: String = UUID().uuidString,
        visibility: Visibility = .private,
        preview: String = "",
        content: Content,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        isArchived: Bool = false
    ) {
        self.id = id
        self.visibility = visibility
        self.preview = preview
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
    }
}

// MARK: - RecordFilter (搜索/过滤条件)
struct RecordFilter {
    var searchText: String = ""
    var tagIDs: Set<String> = []
    var tagMatchAny: Bool = false
    var fileTypes: Set<Record.FileType> = []
    var dateRange: ClosedRange<Date>? = nil
    var showArchived: Bool = false
    var showOnlyPinned: Bool = false
    var showPinnedFirst: Bool = true

    var isEmpty: Bool {
        searchText.isEmpty && tagIDs.isEmpty && fileTypes.isEmpty && dateRange == nil && !showArchived && !showOnlyPinned
    }
}
