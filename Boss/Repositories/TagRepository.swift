import Foundation

// MARK: - TagRepository
final class TagRepository {
    private let db = DatabaseManager.shared
    private var currentUserID: String { AppConfig.shared.currentUserID }

    func create(_ tag: Tag) throws {
        try db.write("""
            INSERT INTO tags (id, user_id, name, parent_id, color, icon, created_at, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(tag.id), .text(currentUserID), .text(tag.name),
                tag.parentID.map { .text($0) } ?? .null,
                .text(tag.color), .text(tag.icon),
                .real(tag.createdAt.timeIntervalSince1970), .integer(tag.sortOrder)
            ])
    }

    func fetchAll() throws -> [Tag] {
        try db.read(
            "SELECT * FROM tags WHERE user_id = ? ORDER BY sort_order, name",
            bindings: [.text(currentUserID)],
            map: mapRow
        )
    }

    func update(_ tag: Tag) throws {
        try db.write("""
            UPDATE tags SET name=?, parent_id=?, color=?, icon=?, sort_order=? WHERE id=? AND user_id=?
            """, bindings: [
                .text(tag.name),
                tag.parentID.map { .text($0) } ?? .null,
                .text(tag.color), .text(tag.icon),
                .integer(tag.sortOrder), .text(tag.id), .text(currentUserID)
            ])
    }

    func delete(id: String) throws {
        try db.write("DELETE FROM tags WHERE id = ? AND user_id = ?", bindings: [.text(id), .text(currentUserID)])
    }

    func recordCount(tagID: String) throws -> Int {
        let rows = try db.read(
            """
            SELECT COUNT(*) as cnt
            FROM record_tags rt
            JOIN records r ON r.id = rt.record_id
            WHERE rt.tag_id = ? AND r.user_id = ?
            """,
            bindings: [.text(tagID), .text(currentUserID)],
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

// MARK: - UserRepository
final class UserRepository {
    private let db = DatabaseManager.shared

    func ensureDefaultUserExists() throws {
        let now = Date().timeIntervalSince1970
        try db.write(
            """
            INSERT OR IGNORE INTO users (id, name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [
                .text(AppConfig.defaultUserID),
                .text("默认用户"),
                .real(now),
                .real(now),
            ]
        )
    }

    @discardableResult
    func ensureUserExists(id: String, fallbackName: String? = nil) throws -> UserProfile {
        let normalized = AppConfig.normalizeUserID(id)
        if let existing = try fetchByID(normalized) {
            return existing
        }
        let now = Date().timeIntervalSince1970
        let safeName = normalizeName(fallbackName ?? normalized)
        try db.write(
            """
            INSERT INTO users (id, name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [
                .text(normalized),
                .text(safeName),
                .real(now),
                .real(now),
            ]
        )
        return UserProfile(id: normalized, name: safeName, createdAt: Date(timeIntervalSince1970: now), updatedAt: Date(timeIntervalSince1970: now))
    }

    func fetchAll() throws -> [UserProfile] {
        try db.read(
            "SELECT * FROM users ORDER BY updated_at DESC, name ASC",
            bindings: [],
            map: mapUserRow
        )
    }

    func fetchByID(_ id: String) throws -> UserProfile? {
        let rows = try db.read(
            "SELECT * FROM users WHERE id = ? LIMIT 1",
            bindings: [.text(id)],
            map: mapUserRow
        )
        return rows.first
    }

    @discardableResult
    func create(name rawName: String) throws -> UserProfile {
        let name = normalizeName(rawName)
        let id = UUID().uuidString.lowercased()
        let now = Date().timeIntervalSince1970
        try db.write(
            """
            INSERT INTO users (id, name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [
                .text(id),
                .text(name),
                .real(now),
                .real(now),
            ]
        )
        return UserProfile(id: id, name: name, createdAt: Date(timeIntervalSince1970: now), updatedAt: Date(timeIntervalSince1970: now))
    }

    private func normalizeName(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "未命名用户" : value
    }

    private func mapUserRow(_ row: [String: SQLValue]) -> UserProfile? {
        guard
            let id = row["id"]?.stringValue,
            let name = row["name"]?.stringValue,
            let createdAt = row["created_at"]?.doubleValue,
            let updatedAt = row["updated_at"]?.doubleValue
        else {
            return nil
        }
        return UserProfile(
            id: id,
            name: name,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
