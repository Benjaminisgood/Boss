import Foundation

// MARK: - SQL 建表语句 (SQLite3 原生，无外部依赖)
enum Schema {
    static let createRecords = """
    CREATE TABLE IF NOT EXISTS records (
        id          TEXT PRIMARY KEY,
        visibility  TEXT NOT NULL DEFAULT 'private',
        preview     TEXT NOT NULL DEFAULT '',
        kind        TEXT NOT NULL DEFAULT 'file',
        file_type   TEXT NOT NULL DEFAULT 'file',
        text_preview TEXT NOT NULL DEFAULT '',
        file_path   TEXT NOT NULL DEFAULT '',
        filename    TEXT NOT NULL DEFAULT '',
        content_type TEXT NOT NULL DEFAULT 'application/octet-stream',
        size_bytes  INTEGER NOT NULL DEFAULT 0,
        sha256      TEXT NOT NULL DEFAULT '',
        created_at  REAL NOT NULL,
        updated_at  REAL NOT NULL,
        is_pinned   INTEGER NOT NULL DEFAULT 0,
        is_archived INTEGER NOT NULL DEFAULT 0
    );
    """

    static let createTags = """
    CREATE TABLE IF NOT EXISTS tags (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        parent_id   TEXT,
        color       TEXT NOT NULL DEFAULT '#007AFF',
        icon        TEXT NOT NULL DEFAULT 'tag',
        created_at  REAL NOT NULL,
        sort_order  INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (parent_id) REFERENCES tags(id) ON DELETE SET NULL
    );
    """

    static let createRecordTags = """
    CREATE TABLE IF NOT EXISTS record_tags (
        record_id   TEXT NOT NULL,
        tag_id      TEXT NOT NULL,
        PRIMARY KEY (record_id, tag_id),
        FOREIGN KEY (record_id) REFERENCES records(id) ON DELETE CASCADE,
        FOREIGN KEY (tag_id)    REFERENCES tags(id)    ON DELETE CASCADE
    );
    """

    static let createAgentTasks = """
    CREATE TABLE IF NOT EXISTS agent_tasks (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        description     TEXT NOT NULL DEFAULT '',
        template_id     TEXT,
        trigger_json    TEXT NOT NULL DEFAULT '{}',
        action_json     TEXT NOT NULL DEFAULT '{}',
        is_enabled      INTEGER NOT NULL DEFAULT 1,
        last_run_at     REAL,
        next_run_at     REAL,
        created_at      REAL NOT NULL,
        output_tag_id   TEXT
    );
    """

    static let createAgentRunLogs = """
    CREATE TABLE IF NOT EXISTS agent_run_logs (
        id          TEXT PRIMARY KEY,
        task_id     TEXT NOT NULL,
        started_at  REAL NOT NULL,
        finished_at REAL,
        status      TEXT NOT NULL DEFAULT 'running',
        output      TEXT NOT NULL DEFAULT '',
        error       TEXT,
        FOREIGN KEY (task_id) REFERENCES agent_tasks(id) ON DELETE CASCADE
    );
    """

    static let createAssistantSkills = """
    CREATE TABLE IF NOT EXISTS assistant_skills (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        description     TEXT NOT NULL DEFAULT '',
        trigger_hint    TEXT NOT NULL DEFAULT '',
        action_json     TEXT NOT NULL DEFAULT '{}',
        is_enabled      INTEGER NOT NULL DEFAULT 1,
        created_at      REAL NOT NULL,
        updated_at      REAL NOT NULL
    );
    """

    // FTS5 全文搜索虚拟表
    static let createFTS = """
    CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(
        id UNINDEXED,
        preview,
        text_preview,
        filename,
        file_type,
        content='records',
        content_rowid='rowid'
    );
    """

    static let createFTSTriggers = """
    CREATE TRIGGER IF NOT EXISTS records_ai AFTER INSERT ON records BEGIN
        INSERT INTO records_fts(rowid, id, preview, text_preview, filename, file_type)
        VALUES (new.rowid, new.id, new.preview, new.text_preview, new.filename, new.file_type);
    END;
    CREATE TRIGGER IF NOT EXISTS records_ad AFTER DELETE ON records BEGIN
        INSERT INTO records_fts(records_fts, rowid, id, preview, text_preview, filename, file_type)
        VALUES ('delete', old.rowid, old.id, old.preview, old.text_preview, old.filename, old.file_type);
    END;
    CREATE TRIGGER IF NOT EXISTS records_au AFTER UPDATE ON records BEGIN
        INSERT INTO records_fts(records_fts, rowid, id, preview, text_preview, filename, file_type)
        VALUES ('delete', old.rowid, old.id, old.preview, old.text_preview, old.filename, old.file_type);
        INSERT INTO records_fts(rowid, id, preview, text_preview, filename, file_type)
        VALUES (new.rowid, new.id, new.preview, new.text_preview, new.filename, new.file_type);
    END;
    """

    static let createIndexes = """
    CREATE INDEX IF NOT EXISTS idx_records_updated_at ON records(updated_at DESC);
    CREATE INDEX IF NOT EXISTS idx_records_created_at ON records(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_records_file_type ON records(file_type);
    CREATE INDEX IF NOT EXISTS idx_records_filename ON records(filename);
    CREATE INDEX IF NOT EXISTS idx_record_tags_tag_id ON record_tags(tag_id);
    CREATE INDEX IF NOT EXISTS idx_agent_tasks_next_run ON agent_tasks(next_run_at);
    CREATE INDEX IF NOT EXISTS idx_assistant_skills_enabled ON assistant_skills(is_enabled);
    """
}
