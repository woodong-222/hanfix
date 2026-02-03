//
//  Database.swift
//  HanFix
//
//  SQLite 데이터베이스 연결 및 마이그레이션 관리
//

import Foundation
import SQLite3

/// SQLite 데이터베이스 관리자
final class Database {
    
    /// 싱글톤 인스턴스
    static let shared = Database()
    
    /// SQLite 연결 포인터
    private(set) var db: OpaquePointer?

    /// SQLite 접근 직렬화 큐 (단일 커넥션을 안전하게 사용)
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    
    /// 데이터베이스 파일 경로
    let databasePath: String
    
    /// 현재 스키마 버전
    static let currentSchemaVersion = 1
    
    private init() {
        queue = DispatchQueue(label: "com.hanfix.database")
        queue.setSpecific(key: queueKey, value: ())

        // ~/Library/Application Support/HanFix/hanfix.db
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let hanfixDir = appSupport.appendingPathComponent("HanFix", isDirectory: true)
        
        // 디렉토리 생성
        try? FileManager.default.createDirectory(at: hanfixDir, withIntermediateDirectories: true)
        
        databasePath = hanfixDir.appendingPathComponent("hanfix.db").path
    }

    // MARK: - Thread Safety

    /// DB 단일 커넥션 접근을 직렬화하여 실행
    @discardableResult
    func perform<T>(_ work: () throws -> T) rethrows -> T {
        // 이미 DB 큐 위라면 재진입 허용 (inTransaction → upsert 등 중첩 호출 안전)
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync {
            try work()
        }
    }
    
    // MARK: - 연결 관리
    
    /// 데이터베이스 연결 열기
    func open() throws {
        try perform {
            guard db == nil else { return }

            var opened: OpaquePointer?
            let flags = Int32(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
            let result = sqlite3_open_v2(databasePath, &opened, flags, nil)
            db = opened

            guard result == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.openFailed(message)
            }

            // WAL 모드 활성화 (성능 향상)
            try execute("PRAGMA journal_mode=WAL")

            // 외래키 제약 활성화
            try execute("PRAGMA foreign_keys=ON")

            // 마이그레이션 실행
            try runMigrations()
        }
    }
    
    /// 데이터베이스 연결 닫기
    func close() {
        _ = try? perform {
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
        }
    }
    
    // MARK: - 쿼리 실행
    
    /// SQL 문 실행 (결과 없음)
    func execute(_ sql: String) throws {
        try perform {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)

            if result != SQLITE_OK {
                let message = errorMessage.map { String(cString: $0) } ?? "알 수 없는 오류"
                sqlite3_free(errorMessage)
                throw DatabaseError.executeFailed(message)
            }
        }
    }
    
    /// Prepared Statement 생성
    func prepare(_ sql: String) throws -> OpaquePointer? {
        try perform {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)

            guard result == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.prepareFailed(message)
            }

            return statement
        }
    }
    
    /// 트랜잭션 내에서 작업 실행
    func inTransaction<T>(_ work: () throws -> T) throws -> T {
        try perform {
            try execute("BEGIN TRANSACTION")
            do {
                let result = try work()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }
    
    // MARK: - 마이그레이션
    
    /// 마이그레이션 실행
    private func runMigrations() throws {
        // 스키마 버전 테이블 생성
        try execute("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)
        
        let currentVersion = try getCurrentSchemaVersion()

        // 이미 최신(또는 더 높은) 버전이면 마이그레이션 할 것이 없음
        guard currentVersion < Self.currentSchemaVersion else {
            return
        }

        for version in (currentVersion + 1)...Self.currentSchemaVersion {
            try applyMigration(version: version)
            try execute("INSERT INTO schema_version (version) VALUES (\(version))")
        }
    }
    
    /// 현재 스키마 버전 조회
    private func getCurrentSchemaVersion() throws -> Int {
        let statement = try prepare("SELECT MAX(version) FROM schema_version")
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let version = sqlite3_column_int(statement, 0)
            return Int(version)
        }
        return 0
    }
    
    /// 특정 버전 마이그레이션 적용
    private func applyMigration(version: Int) throws {
        switch version {
        case 1:
            try applyMigration_v1()
        default:
            throw DatabaseError.unknownMigration(version)
        }
    }
    
    /// 버전 1 마이그레이션: 초기 스키마
    private func applyMigration_v1() throws {
        // 파일 인덱스 테이블
        try execute("""
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE,
                filename TEXT NOT NULL,
                filename_nfc TEXT NOT NULL,
                is_nfd INTEGER NOT NULL DEFAULT 0,
                file_type TEXT,
                size INTEGER,
                modified_at TEXT,
                indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
                is_excluded INTEGER NOT NULL DEFAULT 0
            )
        """)
        
        // 인덱스 생성
        try execute("CREATE INDEX IF NOT EXISTS idx_files_is_nfd ON files(is_nfd)")
        try execute("CREATE INDEX IF NOT EXISTS idx_files_path ON files(path)")
        try execute("CREATE INDEX IF NOT EXISTS idx_files_filename ON files(filename)")
        
        // 이름 변환 히스토리 테이블
        try execute("""
            CREATE TABLE IF NOT EXISTS rename_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                original_path TEXT NOT NULL,
                original_filename TEXT NOT NULL,
                new_filename TEXT NOT NULL,
                result TEXT NOT NULL,
                error_message TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)
        
        // 히스토리 인덱스
        try execute("CREATE INDEX IF NOT EXISTS idx_history_created_at ON rename_history(created_at DESC)")
        try execute("CREATE INDEX IF NOT EXISTS idx_history_result ON rename_history(result)")
        
        // 설정 테이블
        try execute("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)
    }
}

// MARK: - 에러 정의

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case unknownMigration(Int)
    
    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "데이터베이스 열기 실패: \(message)"
        case .executeFailed(let message):
            return "쿼리 실행 실패: \(message)"
        case .prepareFailed(let message):
            return "쿼리 준비 실패: \(message)"
        case .unknownMigration(let version):
            return "알 수 없는 마이그레이션 버전: \(version)"
        }
    }
}
