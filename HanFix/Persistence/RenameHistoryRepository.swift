//
//  RenameHistoryRepository.swift
//  HanFix
//
//  파일 이름 변환 히스토리 저장소
//

import Foundation
import SQLite3

/// 이름 변환 결과
enum RenameResultType: String {
    case success = "success"      // 성공
    case skipped = "skipped"      // 건너뜀 (제외 규칙)
    case conflict = "conflict"    // 충돌 (대상 파일 존재)
    case failed = "failed"        // 실패 (오류)
}

/// 이름 변환 히스토리 항목
struct RenameHistoryItem: Identifiable {
    let id: Int64
    let originalPath: String
    let originalFilename: String
    let newFilename: String
    let result: RenameResultType
    let errorMessage: String?
    let createdAt: Date
    
    /// 결과 아이콘
    var resultIcon: String {
        switch result {
        case .success: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
    
    /// 결과 색상 이름
    var resultColorName: String {
        switch result {
        case .success: return "green"
        case .skipped: return "gray"
        case .conflict: return "orange"
        case .failed: return "red"
        }
    }
    
    /// 결과 설명 (한국어)
    var resultDescription: String {
        switch result {
        case .success: return "변환 완료"
        case .skipped: return "건너뜀"
        case .conflict: return "이름 충돌"
        case .failed: return "실패"
        }
    }
}

/// 이름 변환 히스토리 저장소
final class RenameHistoryRepository {
    
    private let database: Database
    
    init(database: Database = .shared) {
        self.database = database
    }
    
    // MARK: - 히스토리 추가
    
    /// 히스토리 항목 추가
    func add(
        originalPath: String,
        originalFilename: String,
        newFilename: String,
        result: RenameResultType,
        errorMessage: String? = nil
    ) throws {
        try database.perform {
            let sql = """
                INSERT INTO rename_history (original_path, original_filename, new_filename, result, error_message)
                VALUES (?, ?, ?, ?, ?)
            """

            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, originalPath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, originalFilename, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 3, newFilename, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 4, result.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if let errorMessage = errorMessage {
                sqlite3_bind_text(statement, 5, errorMessage, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(statement, 5)
            }

            if sqlite3_step(statement) != SQLITE_DONE {
                let message = String(cString: sqlite3_errmsg(database.db))
                throw DatabaseError.executeFailed(message)
            }
        }
    }
    
    // MARK: - 히스토리 조회
    
    /// 최근 히스토리 조회
    func getRecent(limit: Int = 50) throws -> [RenameHistoryItem] {
        try database.perform {
            let sql = """
                SELECT * FROM rename_history
                ORDER BY created_at DESC
                LIMIT ?
            """
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, Int32(limit))

            var items: [RenameHistoryItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let item = parseRow(statement) {
                    items.append(item)
                }
            }
            return items
        }
    }
    
    /// 결과 유형별 히스토리 조회
    func getByResult(_ result: RenameResultType, limit: Int = 50) throws -> [RenameHistoryItem] {
        try database.perform {
            let sql = """
                SELECT * FROM rename_history
                WHERE result = ?
                ORDER BY created_at DESC
                LIMIT ?
            """
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, result.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(statement, 2, Int32(limit))

            var items: [RenameHistoryItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let item = parseRow(statement) {
                    items.append(item)
                }
            }
            return items
        }
    }
    
    /// 오늘의 통계 조회
    func getTodayStats() throws -> (success: Int, skipped: Int, conflict: Int, failed: Int) {
        try database.perform {
            let sql = """
                SELECT result, COUNT(*) FROM rename_history
                WHERE date(created_at) = date('now')
                GROUP BY result
            """
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            var stats: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let resultCStr = sqlite3_column_text(statement, 0) {
                    let result = String(cString: resultCStr)
                    let count = Int(sqlite3_column_int(statement, 1))
                    stats[result] = count
                }
            }

            return (
                success: stats[RenameResultType.success.rawValue] ?? 0,
                skipped: stats[RenameResultType.skipped.rawValue] ?? 0,
                conflict: stats[RenameResultType.conflict.rawValue] ?? 0,
                failed: stats[RenameResultType.failed.rawValue] ?? 0
            )
        }
    }
    
    /// 전체 통계 조회
    func getTotalStats() throws -> (success: Int, skipped: Int, conflict: Int, failed: Int) {
        try database.perform {
            let sql = """
                SELECT result, COUNT(*) FROM rename_history
                GROUP BY result
            """
            guard let statement = try database.prepare(sql) else {
                throw DatabaseError.prepareFailed("prepare 실패")
            }
            defer { sqlite3_finalize(statement) }

            var stats: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let resultCStr = sqlite3_column_text(statement, 0) {
                    let result = String(cString: resultCStr)
                    let count = Int(sqlite3_column_int(statement, 1))
                    stats[result] = count
                }
            }

            return (
                success: stats[RenameResultType.success.rawValue] ?? 0,
                skipped: stats[RenameResultType.skipped.rawValue] ?? 0,
                conflict: stats[RenameResultType.conflict.rawValue] ?? 0,
                failed: stats[RenameResultType.failed.rawValue] ?? 0
            )
        }
    }
    
    /// 오래된 히스토리 삭제 (정리)
    func deleteOlderThan(days: Int) throws {
        try database.perform {
            let sql = """
                DELETE FROM rename_history
                WHERE created_at < datetime('now', '-\(days) days')
            """
            try database.execute(sql)
        }
    }
    
    // MARK: - Private
    
    private func parseRow(_ statement: OpaquePointer?) -> RenameHistoryItem? {
        guard let statement = statement else { return nil }
        
        let formatter = ISO8601DateFormatter()
        
        let id = sqlite3_column_int64(statement, 0)
        
        guard let originalPathCStr = sqlite3_column_text(statement, 1),
              let originalFilenameCStr = sqlite3_column_text(statement, 2),
              let newFilenameCStr = sqlite3_column_text(statement, 3),
              let resultCStr = sqlite3_column_text(statement, 4) else {
            return nil
        }
        
        let originalPath = String(cString: originalPathCStr)
        let originalFilename = String(cString: originalFilenameCStr)
        let newFilename = String(cString: newFilenameCStr)
        let resultString = String(cString: resultCStr)
        
        guard let result = RenameResultType(rawValue: resultString) else {
            return nil
        }
        
        let errorMessage: String? = sqlite3_column_text(statement, 5).map { String(cString: $0) }
        
        let createdAtCStr = sqlite3_column_text(statement, 6)
        let createdAt = createdAtCStr.flatMap { formatter.date(from: String(cString: $0)) } ?? Date()
        
        return RenameHistoryItem(
            id: id,
            originalPath: originalPath,
            originalFilename: originalFilename,
            newFilename: newFilename,
            result: result,
            errorMessage: errorMessage,
            createdAt: createdAt
        )
    }
}
