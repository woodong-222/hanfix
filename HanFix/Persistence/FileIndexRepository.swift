//
//  FileIndexRepository.swift
//  HanFix
//
//  파일 인덱스 저장소
//

import Foundation
import SQLite3

/// 인덱싱된 파일 정보
struct IndexedFile: Identifiable {
    let id: Int64
    let path: String
    let filename: String
    let filenameNFC: String
    let isNFD: Bool
    let fileType: String?
    let size: Int64?
    let modifiedAt: Date?
    let indexedAt: Date
    let isExcluded: Bool
    
    /// 파일의 디렉토리 경로
    var directoryPath: String {
        (path as NSString).deletingLastPathComponent
    }
}

/// 파일 인덱스 저장소
final class FileIndexRepository {
    
    private let database: Database
    
    init(database: Database = .shared) {
        self.database = database
    }
    
    // MARK: - CRUD
    
    /// 파일 정보 삽입 또는 업데이트
    func upsert(_ file: IndexedFile) throws {
        try database.perform {
            let sql = """
                INSERT INTO files (path, filename, filename_nfc, is_nfd, file_type, size, modified_at, is_excluded)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    filename = excluded.filename,
                    filename_nfc = excluded.filename_nfc,
                    is_nfd = excluded.is_nfd,
                    file_type = excluded.file_type,
                    size = excluded.size,
                    modified_at = excluded.modified_at,
                    indexed_at = datetime('now'),
                    is_excluded = excluded.is_excluded
            """

            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, file.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, file.filename, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 3, file.filenameNFC, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(statement, 4, file.isNFD ? 1 : 0)

            if let fileType = file.fileType {
                sqlite3_bind_text(statement, 5, fileType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(statement, 5)
            }

            if let size = file.size {
                sqlite3_bind_int64(statement, 6, size)
            } else {
                sqlite3_bind_null(statement, 6)
            }

            if let modifiedAt = file.modifiedAt {
                let formatter = ISO8601DateFormatter()
                sqlite3_bind_text(statement, 7, formatter.string(from: modifiedAt), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(statement, 7)
            }

            sqlite3_bind_int(statement, 8, file.isExcluded ? 1 : 0)

            if sqlite3_step(statement) != SQLITE_DONE {
                let message = String(cString: sqlite3_errmsg(database.db))
                throw DatabaseError.executeFailed(message)
            }
        }
    }
    
    /// 배치 삽입 (트랜잭션)
    func batchUpsert(_ files: [IndexedFile]) throws {
        try database.inTransaction {
            for file in files {
                try upsert(file)
            }
        }
    }
    
    /// 경로로 파일 조회
    func findByPath(_ path: String) throws -> IndexedFile? {
        try database.perform {
            let sql = "SELECT * FROM files WHERE path = ?"
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(statement) == SQLITE_ROW {
                return parseRow(statement)
            }
            return nil
        }
    }
    
    /// NFD 파일 목록 조회
    func findNFDFiles(limit: Int = 100, offset: Int = 0) throws -> [IndexedFile] {
        try database.perform {
            let sql = """
                SELECT * FROM files 
                WHERE is_nfd = 1 AND is_excluded = 0
                  AND (file_type IS NULL OR file_type != 'directory')
                ORDER BY indexed_at DESC
                LIMIT ? OFFSET ?
            """
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, Int32(limit))
            sqlite3_bind_int(statement, 2, Int32(offset))

            var files: [IndexedFile] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let file = parseRow(statement) {
                    files.append(file)
                }
            }
            return files
        }
    }
    
    /// NFD 파일 개수 조회
    func countNFDFiles() throws -> Int {
        try database.perform {
            let sql = "SELECT COUNT(*) FROM files WHERE is_nfd = 1 AND is_excluded = 0 AND (file_type IS NULL OR file_type != 'directory')"
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            if sqlite3_step(statement) == SQLITE_ROW {
                return Int(sqlite3_column_int64(statement, 0))
            }
            return 0
        }
    }
    
    /// 전체 파일 개수 조회
    func countAllFiles() throws -> Int {
        try database.perform {
            let sql = "SELECT COUNT(*) FROM files"
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            if sqlite3_step(statement) == SQLITE_ROW {
                return Int(sqlite3_column_int64(statement, 0))
            }
            return 0
        }
    }
    
    /// 경로로 파일 삭제
    func deleteByPath(_ path: String) throws {
        try database.perform {
            let sql = "DELETE FROM files WHERE path = ?"
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(statement) != SQLITE_DONE {
                let message = String(cString: sqlite3_errmsg(database.db))
                throw DatabaseError.executeFailed(message)
            }
        }
    }
    
    /// 경로 업데이트 (이름 변경 후)
    func updatePath(from oldPath: String, to newPath: String, newFilename: String, newFilenameNFC: String) throws {
        try database.perform {
            let sql = """
                UPDATE files SET 
                    path = ?,
                    filename = ?,
                    filename_nfc = ?,
                    is_nfd = 0,
                    indexed_at = datetime('now')
                WHERE path = ?
            """
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, newPath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, newFilename, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 3, newFilenameNFC, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 4, oldPath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(statement) != SQLITE_DONE {
                let message = String(cString: sqlite3_errmsg(database.db))
                throw DatabaseError.executeFailed(message)
            }
        }
    }
    
    // MARK: - Private
    
    private func parseRow(_ statement: OpaquePointer?) -> IndexedFile? {
        guard let statement = statement else { return nil }
        
        let formatter = ISO8601DateFormatter()
        
        let id = sqlite3_column_int64(statement, 0)
        
        guard let pathCStr = sqlite3_column_text(statement, 1),
              let filenameCStr = sqlite3_column_text(statement, 2),
              let filenameNFCCStr = sqlite3_column_text(statement, 3) else {
            return nil
        }
        
        let path = String(cString: pathCStr)
        let filename = String(cString: filenameCStr)
        let filenameNFC = String(cString: filenameNFCCStr)
        let isNFD = sqlite3_column_int(statement, 4) == 1
        
        let fileType: String? = sqlite3_column_text(statement, 5).map { String(cString: $0) }
        
        let size: Int64? = sqlite3_column_type(statement, 6) != SQLITE_NULL 
            ? sqlite3_column_int64(statement, 6) : nil
        
        let modifiedAt: Date? = sqlite3_column_text(statement, 7)
            .flatMap { formatter.date(from: String(cString: $0)) }
        
        let indexedAtCStr = sqlite3_column_text(statement, 8)
        let indexedAt = indexedAtCStr.flatMap { formatter.date(from: String(cString: $0)) } ?? Date()
        
        let isExcluded = sqlite3_column_int(statement, 9) == 1
        
        return IndexedFile(
            id: id,
            path: path,
            filename: filename,
            filenameNFC: filenameNFC,
            isNFD: isNFD,
            fileType: fileType,
            size: size,
            modifiedAt: modifiedAt,
            indexedAt: indexedAt,
            isExcluded: isExcluded
        )
    }
}
