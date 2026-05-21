import Foundation
import SQLite3

public struct AppConfig: Codable, Equatable, Sendable {
    public var rule: TimerRule
    public var evaluationIntervalSeconds: TimeInterval
    public var targetDurationSeconds: TimeInterval
    public var monthlyAverageTargetSeconds: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case rule
        case evaluationIntervalSeconds
        case targetDurationSeconds
        case monthlyAverageTargetSeconds
    }

    public init(
        rule: TimerRule,
        evaluationIntervalSeconds: TimeInterval,
        targetDurationSeconds: TimeInterval = 10.5 * 60 * 60,
        monthlyAverageTargetSeconds: TimeInterval = 10.5 * 60 * 60
    ) {
        self.rule = rule
        self.evaluationIntervalSeconds = evaluationIntervalSeconds
        self.targetDurationSeconds = targetDurationSeconds
        self.monthlyAverageTargetSeconds = monthlyAverageTargetSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rule = try container.decode(TimerRule.self, forKey: .rule)
        self.evaluationIntervalSeconds = try container.decode(TimeInterval.self, forKey: .evaluationIntervalSeconds)
        self.targetDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .targetDurationSeconds) ?? 10.5 * 60 * 60
        self.monthlyAverageTargetSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .monthlyAverageTargetSeconds) ?? self.targetDurationSeconds
    }

    public static let `default` = AppConfig(
        rule: .defaultRule,
        evaluationIntervalSeconds: 60,
        targetDurationSeconds: 10.5 * 60 * 60,
        monthlyAverageTargetSeconds: 10.5 * 60 * 60
    )
}

public struct DakaPaths: Sendable {
    public var appSupportDirectory: URL
    public var configURL: URL
    public var recordsURL: URL
    public var databaseURL: URL

    public init(baseDirectory: URL? = nil) throws {
        let directory: URL
        if let baseDirectory {
            directory = baseDirectory
        } else {
            directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Daka", isDirectory: true)
        }

        self.appSupportDirectory = directory
        self.configURL = directory.appendingPathComponent("config.json")
        self.recordsURL = directory.appendingPathComponent("records.json")
        self.databaseURL = directory.appendingPathComponent("daka.sqlite")
    }
}

public final class DakaStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let paths: DakaPaths
    private var db: OpaquePointer?

    public init(paths: DakaPaths) throws {
        self.paths = paths
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try ensureDirectory()
        try open()
        try migrateSchema()
        try migrateLegacyJSONIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    public func loadConfig() throws -> AppConfig {
        let sql = "SELECT value FROM app_config WHERE key = 'default' LIMIT 1;"
        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        try prepare(sql, statement: &statement)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            try saveConfig(.default)
            return .default
        }

        let data = Data(String(cString: text).utf8)
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func saveConfig(_ config: AppConfig) throws {
        let data = try encoder.encode(config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw StoreError.invalidStringEncoding
        }

        let sql = """
        INSERT INTO app_config(key, value, updated_at)
        VALUES('default', ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            value = excluded.value,
            updated_at = excluded.updated_at;
        """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        try prepare(sql, statement: &statement)
        try bind(json, to: statement, index: 1)
        try bind(Date().timeIntervalSince1970, to: statement, index: 2)
        try stepDone(statement)
    }

    public func loadRecords() throws -> [DailyRecord] {
        let sql = """
        SELECT date, first_matched_at, last_matched_at
        FROM daily_records
        ORDER BY date ASC;
        """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        try prepare(sql, statement: &statement)

        var records: [DailyRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let date = String(cString: sqlite3_column_text(statement, 0))
            let firstMatchedAt = optionalDate(statement, column: 1)
            let lastMatchedAt = optionalDate(statement, column: 2)
            records.append(DailyRecord(date: date, firstMatchedAt: firstMatchedAt, lastMatchedAt: lastMatchedAt))
        }

        return records
    }

    public func saveRecords(_ records: [DailyRecord]) throws {
        try transaction {
            for record in records {
                try saveRecord(record)
            }
        }
    }

    private func saveRecord(_ record: DailyRecord) throws {
        let sql = """
        INSERT INTO daily_records(date, first_matched_at, last_matched_at, updated_at)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET
            first_matched_at = excluded.first_matched_at,
            last_matched_at = excluded.last_matched_at,
            updated_at = excluded.updated_at;
        """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        try prepare(sql, statement: &statement)
        try bind(record.date, to: statement, index: 1)
        try bindOptionalDate(record.firstMatchedAt, to: statement, index: 2)
        try bindOptionalDate(record.lastMatchedAt, to: statement, index: 3)
        try bind(Date().timeIntervalSince1970, to: statement, index: 4)
        try stepDone(statement)
    }

    private func open() throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(paths.databaseURL.path, &db, flags, nil) != SQLITE_OK {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    private func migrateSchema() throws {
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("""
        CREATE TABLE IF NOT EXISTS app_config (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS daily_records (
            date TEXT PRIMARY KEY NOT NULL,
            first_matched_at REAL,
            last_matched_at REAL,
            updated_at REAL NOT NULL
        );
        """)
    }

    private func migrateLegacyJSONIfNeeded() throws {
        let configExists = try hasConfig()
        let recordsExist = try hasRecords()

        let legacy = LegacyJSONFileStore(paths: paths)

        if !configExists, FileManager.default.fileExists(atPath: paths.configURL.path) {
            try saveConfig(try legacy.loadConfig())
        } else if !configExists {
            try saveConfig(.default)
        }

        if !recordsExist, FileManager.default.fileExists(atPath: paths.recordsURL.path) {
            try saveRecords(try legacy.loadRecords())
        }
    }

    private func hasConfig() throws -> Bool {
        try exists("SELECT 1 FROM app_config WHERE key = 'default' LIMIT 1;")
    }

    private func hasRecords() throws -> Bool {
        try exists("SELECT 1 FROM daily_records LIMIT 1;")
    }

    private func exists(_ sql: String) throws -> Bool {
        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        try prepare(sql, statement: &statement)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try work()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        if sqlite3_step(statement) != SQLITE_DONE {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) throws {
        if sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    private func bind(_ value: TimeInterval, to statement: OpaquePointer?, index: Int32) throws {
        if sqlite3_bind_double(statement, index, value) != SQLITE_OK {
            throw StoreError.sqlite(message: lastErrorMessage)
        }
    }

    private func bindOptionalDate(_ date: Date?, to statement: OpaquePointer?, index: Int32) throws {
        guard let date else {
            if sqlite3_bind_null(statement, index) != SQLITE_OK {
                throw StoreError.sqlite(message: lastErrorMessage)
            }
            return
        }

        try bind(date.timeIntervalSince1970, to: statement, index: index)
    }

    private func optionalDate(_ statement: OpaquePointer?, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }

        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private var lastErrorMessage: String {
        guard let db, let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }

        return String(cString: message)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: paths.appSupportDirectory,
            withIntermediateDirectories: true
        )
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum StoreError: Error {
    case invalidStringEncoding
    case sqlite(message: String)
}

private final class LegacyJSONFileStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let paths: DakaPaths

    init(paths: DakaPaths) {
        self.paths = paths
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func loadConfig() throws -> AppConfig {
        try ensureDirectory()

        guard FileManager.default.fileExists(atPath: paths.configURL.path) else {
            try saveConfig(.default)
            return .default
        }

        let data = try Data(contentsOf: paths.configURL)
        return try decoder.decode(AppConfig.self, from: data)
    }

    func saveConfig(_ config: AppConfig) throws {
        try ensureDirectory()
        let data = try encoder.encode(config)
        try data.write(to: paths.configURL, options: .atomic)
    }

    func loadRecords() throws -> [DailyRecord] {
        try ensureDirectory()

        guard FileManager.default.fileExists(atPath: paths.recordsURL.path) else {
            return []
        }

        let data = try Data(contentsOf: paths.recordsURL)
        return try decoder.decode([DailyRecord].self, from: data)
    }

    func saveRecords(_ records: [DailyRecord]) throws {
        try ensureDirectory()
        let data = try encoder.encode(records.sorted { $0.date < $1.date })
        try data.write(to: paths.recordsURL, options: .atomic)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: paths.appSupportDirectory,
            withIntermediateDirectories: true
        )
    }
}
