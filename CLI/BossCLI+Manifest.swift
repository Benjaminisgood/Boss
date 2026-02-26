import Foundation
import SQLite3

extension BossCLI {
    func loadSkillManifestText(refreshIfMissing: Bool) throws -> String {
        let skillTagID = try ensureTag(name: "SkillPack", aliases: ["技能包", "skill package", "skills"], color: "#34C759", icon: "sparkles.rectangle.stack")
        if let record = try findSkillManifestRecord(tagID: skillTagID) {
            let filePath = record["file_path"]?.stringValue ?? ""
            guard !filePath.isEmpty else {
                throw CLIError.invalidData("Skill manifest file path is empty")
            }
            return try readText(relativePath: filePath, maxBytes: 1_000_000)
        }

        if refreshIfMissing {
            _ = try refreshSkillManifestRecord()
            if let record = try findSkillManifestRecord(tagID: skillTagID) {
                let filePath = record["file_path"]?.stringValue ?? ""
                guard !filePath.isEmpty else {
                    throw CLIError.invalidData("Skill manifest file path is empty")
                }
                return try readText(relativePath: filePath, maxBytes: 1_000_000)
            }
        }

        return buildSkillManifestText(skills: [])
    }

    @discardableResult
    func refreshSkillManifestRecord() throws -> String {
        let skillTagID = try ensureTag(name: "SkillPack", aliases: ["技能包", "skill package", "skills"], color: "#34C759", icon: "sparkles.rectangle.stack")
        let skills = try fetchSkills()
        let manifest = buildSkillManifestText(skills: skills)

        if let existing = try findSkillManifestRecord(tagID: skillTagID),
           let recordID = existing["id"]?.stringValue,
           !recordID.isEmpty {
            _ = try replaceRecordText(recordID: recordID, text: manifest)
            return recordID
        }

        return try createTextRecord(filename: "assistant-skill-manifest.md", text: manifest, tags: [skillTagID])
    }

    func findSkillManifestRecord(tagID: String) throws -> [String: SQLColumnValue]? {
        let rows = try db.query(
            """
            SELECT r.id, r.file_path, r.filename, r.updated_at
            FROM records r
            JOIN record_tags rt ON rt.record_id = r.id
            WHERE rt.tag_id = ? AND lower(r.filename) = 'assistant-skill-manifest.md'
            ORDER BY r.updated_at DESC
            LIMIT 1
            """,
            bindings: [.text(tagID)]
        )
        return rows.first
    }

    func fetchSkills() throws -> [(id: String, name: String, description: String, triggerHint: String, isEnabled: Bool, action: String, updatedAt: Double)] {
        let rows = try db.query(
            """
            SELECT id, name, description, trigger_hint, is_enabled, action_json, updated_at
            FROM assistant_skills
            ORDER BY created_at DESC
            """
        )
        let decoder = JSONDecoder()

        return rows.map { row in
            let actionRaw = row["action_json"]?.stringValue ?? "{}"
            let actionText: String
            if let data = actionRaw.data(using: .utf8),
               let action = try? decoder.decode(CLISkillAction.self, from: data) {
                actionText = describeSkillAction(action)
            } else {
                actionText = "unknown"
            }

            return (
                id: row["id"]?.stringValue ?? "",
                name: row["name"]?.stringValue ?? "",
                description: row["description"]?.stringValue ?? "",
                triggerHint: row["trigger_hint"]?.stringValue ?? "",
                isEnabled: (row["is_enabled"]?.intValue ?? 0) == 1,
                action: actionText,
                updatedAt: row["updated_at"]?.doubleValue ?? 0
            )
        }
    }

    func buildSkillManifestText(skills: [(id: String, name: String, description: String, triggerHint: String, isEnabled: Bool, action: String, updatedAt: Double)]) -> String {
        let blocks = skills.map { skill in
            """
            ## \(skill.name)
            - id: \(skill.id)
            - enabled: \(skill.isEnabled ? "yes" : "no")
            - trigger_hint: \(skill.triggerHint.isEmpty ? "-" : skill.triggerHint)
            - description: \(skill.description.isEmpty ? "-" : shortText(skill.description, limit: 180))
            - action: \(skill.action)
            - updated_at: \(skill.updatedAt > 0 ? iso8601(Date(timeIntervalSince1970: skill.updatedAt)) : "-")
            """
        }.joined(separator: "\n\n")

        return """
        # Assistant Skill Manifest
        generated_at: \(iso8601Now())
        skills_total: \(skills.count)

        ## Base Interfaces
        - assistant.help
        - core.summarize
        - record.search
        - record.create
        - record.append
        - record.replace
        - record.delete
        - task.run
        - skill.run
        - skills.catalog

        ## Skills
        \(blocks.isEmpty ? "- (empty)" : blocks)
        """
    }

}
