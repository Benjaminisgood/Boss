import Foundation

// MARK: - TagRepository
final class TagRepository {
    private let db = DatabaseManager.shared

    func create(_ tag: Tag) throws {
        try db.write("""
            INSERT INTO tags (id, name, parent_id, color, icon, created_at, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(tag.id), .text(tag.name),
                tag.parentID.map { .text($0) } ?? .null,
                .text(tag.color), .text(tag.icon),
                .real(tag.createdAt.timeIntervalSince1970), .integer(tag.sortOrder)
            ])
    }

    func fetchAll() throws -> [Tag] {
        try db.read("SELECT * FROM tags ORDER BY sort_order, name", bindings: [], map: mapRow)
    }

    func update(_ tag: Tag) throws {
        try db.write("""
            UPDATE tags SET name=?, parent_id=?, color=?, icon=?, sort_order=? WHERE id=?
            """, bindings: [
                .text(tag.name),
                tag.parentID.map { .text($0) } ?? .null,
                .text(tag.color), .text(tag.icon),
                .integer(tag.sortOrder), .text(tag.id)
            ])
    }

    func delete(id: String) throws {
        try db.write("DELETE FROM tags WHERE id = ?", bindings: [.text(id)])
    }

    func recordCount(tagID: String) throws -> Int {
        let rows = try db.read(
            "SELECT COUNT(*) as cnt FROM record_tags WHERE tag_id = ?",
            bindings: [.text(tagID)],
            map: { $0["cnt"]?.intValue }
        )
        return rows.first ?? 0
    }

    // MARK: - Build Tree
    func buildTree() throws -> [TagTreeNode] {
        let tags = try fetchAll()
        var countMap: [String: Int] = [:]
        for tag in tags {
            countMap[tag.id] = (try? recordCount(tagID: tag.id)) ?? 0
        }
        return buildNodes(tags: tags, parentID: nil, countMap: countMap)
    }

    private func buildNodes(tags: [Tag], parentID: String?, countMap: [String: Int]) -> [TagTreeNode] {
        tags.filter { $0.parentID == parentID }.map { tag in
            TagTreeNode(
                tag: tag,
                children: buildNodes(tags: tags, parentID: tag.id, countMap: countMap),
                recordCount: countMap[tag.id] ?? 0
            )
        }
    }

    private func mapRow(_ row: [String: SQLValue]) -> Tag? {
        guard
            let id = row["id"]?.stringValue,
            let name = row["name"]?.stringValue,
            let color = row["color"]?.stringValue,
            let icon = row["icon"]?.stringValue,
            let createdAt = row["created_at"]?.doubleValue
        else { return nil }
        return Tag(
            id: id, name: name,
            parentID: row["parent_id"]?.stringValue,
            color: color, icon: icon,
            createdAt: Date(timeIntervalSince1970: createdAt),
            sortOrder: row["sort_order"]?.intValue ?? 0
        )
    }
}
