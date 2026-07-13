import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseService {
    nonisolated(unsafe) static let live: DatabaseService = {
        #if targetEnvironment(simulator) || os(macOS)
            let dbPath = "training.db"
        #else
            let dbPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first! + "/training.db"
        #endif
        return try! DatabaseService(databasePath: dbPath)
    }()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "training.db.serial")

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(databasePath: String) throws {
        let result = sqlite3_open(databasePath, &db)
        guard result == SQLITE_OK, db != nil else {
            throw DatabaseError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try createTables()
        sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func userVersion() -> Int {
        let stmt = try? prepare("PRAGMA user_version")
        defer { if let stmt { sqlite3_finalize(stmt) } }
        guard let stmt, sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func setUserVersion(_ v: Int) {
        sqlite3_exec(db, "PRAGMA user_version = \(v);", nil, nil, nil)
    }

    private func migrate() throws {
        let migrations: [(version: Int, sql: String)] = []
        var current = userVersion()
        if current == 0 { current = 1; setUserVersion(1) }
        for m in migrations where m.version > current {
            try exec(m.sql)
            setUserVersion(m.version)
            current = m.version
        }
    }

    // MARK: - Tables

    private func createTables() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS chat_message (
                id TEXT PRIMARY KEY,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                full_request TEXT,
                token_in INTEGER DEFAULT 0,
                token_out INTEGER DEFAULT 0,
                cost REAL DEFAULT 0.0,
                created_at TEXT NOT NULL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS activity_log (
                id TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                type TEXT NOT NULL,
                duration_min REAL,
                distance_km REAL,
                intensity TEXT,
                notes TEXT,
                created_at TEXT NOT NULL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS user_profile (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS match_schedule (
                id TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                time TEXT,
                opponent TEXT,
                intensity TEXT,
                notes TEXT,
                actual_duration_min REAL,
                actual_intensity TEXT,
                is_completed INTEGER DEFAULT 0,
                created_at TEXT NOT NULL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS cost_record (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                token_in INTEGER DEFAULT 0,
                token_out INTEGER DEFAULT 0,
                cost REAL DEFAULT 0.0,
                created_at TEXT NOT NULL
            )
            """)
    }

    // MARK: - ChatMessage

    func insertChatMessage(_ message: ChatMessage) throws {
        try _insertChatMessage(message)
    }

    func insertChatMessagePair(_ first: ChatMessage, _ second: ChatMessage) throws {
        try exec("BEGIN")
        do {
            try _insertChatMessage(first)
            try _insertChatMessage(second)
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func _insertChatMessage(_ message: ChatMessage) throws {
        let sql = """
            INSERT INTO chat_message (id, role, content, full_request, token_in, token_out, cost, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, message.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, message.role, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, message.content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, message.fullRequest, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, Int64(message.tokenIn))
        sqlite3_bind_int64(stmt, 6, Int64(message.tokenOut))
        sqlite3_bind_double(stmt, 7, message.cost)
        sqlite3_bind_text(stmt, 8, formatDate(message.createdAt), -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    func queryChatMessage(id: String) throws -> ChatMessage? {
        let sql = "SELECT id, role, content, full_request, token_in, token_out, cost, created_at FROM chat_message WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return mapChatMessage(stmt)
    }

    func queryRecentMessages(limit: Int) throws -> [ChatMessage] {
        let sql = "SELECT id, role, content, full_request, token_in, token_out, cost, created_at FROM chat_message ORDER BY created_at DESC LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var messages: [ChatMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let m = mapChatMessage(stmt) { messages.append(m) }
        }
        return messages
    }

    func sumCost() throws -> Double {
        // 合计对话/记录(chat_message) + 趋势/训练(cost_record) 的历史花费
        let stmt = try prepare("SELECT COALESCE(SUM(cost), 0.0) FROM chat_message")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0.0 }
        let chatCost = sqlite3_column_double(stmt, 0)
        let stmt2 = try prepare("SELECT COALESCE(SUM(cost), 0.0) FROM cost_record")
        defer { sqlite3_finalize(stmt2) }
        guard sqlite3_step(stmt2) == SQLITE_ROW else { return chatCost }
        return chatCost + sqlite3_column_double(stmt2, 0)
    }

    /// 记录趋势/训练等非对话 LLM 调用的花费（不污染对话历史 chat_message）。
    func insertCostRecord(source: String, tokenIn: Int, tokenOut: Int, cost: Double) throws {
        let stmt = try prepare("""
            INSERT INTO cost_record (id, source, token_in, token_out, cost, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(tokenIn))
        sqlite3_bind_int64(stmt, 4, Int64(tokenOut))
        sqlite3_bind_double(stmt, 5, cost)
        sqlite3_bind_text(stmt, 6, isoFormatter.string(from: Date()), -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.insertFailed }
    }

    private func mapChatMessage(_ stmt: OpaquePointer) -> ChatMessage? {
        let idString = String(cString: sqlite3_column_text(stmt, 0))
        let role = String(cString: sqlite3_column_text(stmt, 1))
        let content = String(cString: sqlite3_column_text(stmt, 2))
        let fullRequest = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let tokenIn = Int(sqlite3_column_int64(stmt, 4))
        let tokenOut = Int(sqlite3_column_int64(stmt, 5))
        let cost = sqlite3_column_double(stmt, 6)
        let createdAtString = String(cString: sqlite3_column_text(stmt, 7))
        guard let id = UUID(uuidString: idString), let createdAt = parseDate(createdAtString) else { return nil }
        return ChatMessage(id: id, role: role, content: content, fullRequest: fullRequest, tokenIn: tokenIn, tokenOut: tokenOut, cost: cost, createdAt: createdAt)
    }

    // MARK: - ActivityLog

    func queryAllActivities() throws -> [ActivityLog] {
        let sql = "SELECT id, date, type, duration_min, distance_km, intensity, notes, created_at FROM activity_log ORDER BY date DESC"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var logs: [ActivityLog] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let a = mapActivityLog(stmt) { logs.append(a) }
        }
        return logs
    }

    func insertActivityLog(_ log: ActivityLog) throws {
        let sql = """
            INSERT INTO activity_log (id, date, type, duration_min, distance_km, intensity, notes, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, log.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, formatDate(log.date), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, log.type, -1, SQLITE_TRANSIENT)
        if let d = log.durationMin { sqlite3_bind_double(stmt, 4, d) } else { sqlite3_bind_null(stmt, 4) }
        if let d = log.distanceKm { sqlite3_bind_double(stmt, 5, d) } else { sqlite3_bind_null(stmt, 5) }
        if let i = log.intensity { sqlite3_bind_text(stmt, 6, i, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
        if let n = log.notes { sqlite3_bind_text(stmt, 7, n, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 7) }
        sqlite3_bind_text(stmt, 8, formatDate(log.createdAt), -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    func deleteActivity(id: UUID) throws {
        let sql = "DELETE FROM activity_log WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    func updateActivity(_ log: ActivityLog) throws {
        let sql = "UPDATE activity_log SET date=?, type=?, duration_min=?, distance_km=?, intensity=?, notes=? WHERE id=?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, formatDate(log.date), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, log.type, -1, SQLITE_TRANSIENT)
        if let d = log.durationMin { sqlite3_bind_double(stmt, 3, d) } else { sqlite3_bind_null(stmt, 3) }
        if let d = log.distanceKm { sqlite3_bind_double(stmt, 4, d) } else { sqlite3_bind_null(stmt, 4) }
        if let i = log.intensity { sqlite3_bind_text(stmt, 5, i, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
        if let n = log.notes { sqlite3_bind_text(stmt, 6, n, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_text(stmt, 7, log.id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    func queryActivityLog(id: String) throws -> ActivityLog? {
        let sql = "SELECT id, date, type, duration_min, distance_km, intensity, notes, created_at FROM activity_log WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return mapActivityLog(stmt)
    }

    private func mapActivityLog(_ stmt: OpaquePointer) -> ActivityLog? {
        let idString = String(cString: sqlite3_column_text(stmt, 0))
        let dateString = String(cString: sqlite3_column_text(stmt, 1))
        let type = String(cString: sqlite3_column_text(stmt, 2))
        let durationMin: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
        let distanceKm: Double? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4)
        let intensity: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 5))
        let notes: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 6))
        let createdAtString = String(cString: sqlite3_column_text(stmt, 7))
        guard let id = UUID(uuidString: idString), let date = parseDate(dateString), let createdAt = parseDate(createdAtString) else { return nil }
        return ActivityLog(id: id, date: date, type: type, durationMin: durationMin, distanceKm: distanceKm, intensity: intensity, notes: notes, createdAt: createdAt)
    }

    // MARK: - UserProfile

    func queryAllUserProfiles() throws -> [UserProfile] {
        let sql = "SELECT key, value FROM user_profile ORDER BY key"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var profiles: [UserProfile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            profiles.append(UserProfile(
                key: String(cString: sqlite3_column_text(stmt, 0)),
                value: String(cString: sqlite3_column_text(stmt, 1))
            ))
        }
        return profiles
    }

    func setUserProfile(key: String, value: String) throws {
        let sql = "INSERT OR REPLACE INTO user_profile (key, value) VALUES (?, ?)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    func getUserProfile(key: String) throws -> UserProfile? {
        let sql = "SELECT key, value FROM user_profile WHERE key = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return UserProfile(key: String(cString: sqlite3_column_text(stmt, 0)), value: String(cString: sqlite3_column_text(stmt, 1)))
    }

    func deleteUserProfile(key: String) throws {
        let sql = "DELETE FROM user_profile WHERE key = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    // MARK: - Match Schedule

    func insertMatchSchedule(_ match: MatchSchedule) throws {
        let sql = "INSERT INTO match_schedule (id, date, time, opponent, intensity, notes, actual_duration_min, actual_intensity, is_completed, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindMatchSchedule(stmt, match)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    func updateMatchSchedule(_ match: MatchSchedule) throws {
        let sql = "UPDATE match_schedule SET date=?, time=?, opponent=?, intensity=?, notes=?, actual_duration_min=?, actual_intensity=?, is_completed=? WHERE id=?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, formatDate(match.date), -1, SQLITE_TRANSIENT)
        if let t = match.time { sqlite3_bind_text(stmt, 2, t, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 2) }
        if let o = match.opponent { sqlite3_bind_text(stmt, 3, o, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        if let i = match.intensity { sqlite3_bind_text(stmt, 4, i, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
        if let n = match.notes { sqlite3_bind_text(stmt, 5, n, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
        if let d = match.actualDurationMin { sqlite3_bind_double(stmt, 6, d) } else { sqlite3_bind_null(stmt, 6) }
        if let i = match.actualIntensity { sqlite3_bind_text(stmt, 7, i, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 7) }
        sqlite3_bind_int64(stmt, 8, match.isCompleted ? 1 : 0)
        sqlite3_bind_text(stmt, 9, match.id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    func deleteMatchSchedule(id: UUID) throws {
        let sql = "DELETE FROM match_schedule WHERE id = ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
    }

    func queryUpcomingMatches(limit: Int = 5) throws -> [MatchSchedule] {
        let sql = "SELECT id, date, time, opponent, intensity, notes, actual_duration_min, actual_intensity, is_completed, created_at FROM match_schedule WHERE is_completed = 0 AND date >= ? ORDER BY date ASC LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, formatDate(Calendar.current.startOfDay(for: Date())), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        return collectMatches(stmt)
    }

    func queryPastMatches(limit: Int = 50) throws -> [MatchSchedule] {
        let sql = "SELECT id, date, time, opponent, intensity, notes, actual_duration_min, actual_intensity, is_completed, created_at FROM match_schedule WHERE is_completed = 1 OR date < ? ORDER BY date DESC LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, formatDate(Date()), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(limit))
        return collectMatches(stmt)
    }

    func queryAllMatches() throws -> [MatchSchedule] {
        let sql = "SELECT id, date, time, opponent, intensity, notes, actual_duration_min, actual_intensity, is_completed, created_at FROM match_schedule ORDER BY date DESC"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return collectMatches(stmt)
    }

    private func bindMatchSchedule(_ stmt: OpaquePointer, _ m: MatchSchedule) {
        sqlite3_bind_text(stmt, 1, m.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, formatDate(m.date), -1, SQLITE_TRANSIENT)
        if let t = m.time { sqlite3_bind_text(stmt, 3, t, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        if let o = m.opponent { sqlite3_bind_text(stmt, 4, o, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
        if let i = m.intensity { sqlite3_bind_text(stmt, 5, i, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 5) }
        if let n = m.notes { sqlite3_bind_text(stmt, 6, n, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
        if let d = m.actualDurationMin { sqlite3_bind_double(stmt, 7, d) } else { sqlite3_bind_null(stmt, 7) }
        if let i = m.actualIntensity { sqlite3_bind_text(stmt, 8, i, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 8) }
        sqlite3_bind_int64(stmt, 9, m.isCompleted ? 1 : 0)
        sqlite3_bind_text(stmt, 10, formatDate(m.createdAt), -1, SQLITE_TRANSIENT)
    }

    private func collectMatches(_ stmt: OpaquePointer) -> [MatchSchedule] {
        var matches: [MatchSchedule] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let m = mapMatchSchedule(stmt) { matches.append(m) }
        }
        return matches
    }

    private func mapMatchSchedule(_ stmt: OpaquePointer) -> MatchSchedule? {
        guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))),
              let date = parseDate(String(cString: sqlite3_column_text(stmt, 1))) else { return nil }
        return MatchSchedule(
            id: id,
            date: date,
            time: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
            opponent: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            intensity: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            notes: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            actualDurationMin: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6),
            actualIntensity: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
            isCompleted: sqlite3_column_int64(stmt, 8) != 0,
            createdAt: parseDate(String(cString: sqlite3_column_text(stmt, 9))) ?? Date()
        )
    }

    // MARK: - Helpers

    func execRawForTesting(_ sql: String) throws {
        try exec(sql)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func formatDate(_ date: Date) -> String { isoFormatter.string(from: date) }
    private func parseDate(_ string: String) -> Date? { isoFormatter.date(from: string) }
}

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)
    case insertFailed
    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "Open failed: \(m)"
        case .queryFailed(let m): return m
        case .insertFailed: return "Insert failed"
        }
    }
}
