//
//  RenameEngine.swift
//  HanFix
//
//  안전한 파일 이름 변경 엔진
//

import Foundation
import Darwin

/// 이름 변경 결과
enum RenameResult {
    case success(oldPath: String, newPath: String)
    case skipped(reason: SkipReason)
    case failed(error: Error)
    
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// 건너뛰기 이유
enum SkipReason: String {
    case notNFD = "NFD 파일이 아님"
    case targetExists = "대상 파일이 이미 존재함"
    case excluded = "제외 규칙에 해당"
    case permissionDenied = "권한 없음"
    case fileInUse = "파일 사용 중"
    case fileNotFound = "파일을 찾을 수 없음"
    case sameAsOriginal = "원본과 동일"
    
    var description: String { rawValue }
}

/// 안전한 파일 이름 변경 엔진
final class RenameEngine {
    
    /// 싱글톤 인스턴스
    static let shared = RenameEngine()
    
    /// 경로 정책
    private let pathPolicy: PathPolicy
    
    /// 히스토리 저장소
    private var historyRepository: RenameHistoryRepository?
    
    /// 드라이 런 모드
    var dryRun: Bool = false
    
    init(pathPolicy: PathPolicy = .shared) {
        self.pathPolicy = pathPolicy
    }
    
    /// 히스토리 저장소 설정
    func setHistoryRepository(_ repository: RenameHistoryRepository) {
        self.historyRepository = repository
    }
    
    // MARK: - 단일 파일 이름 변경
    
    /// NFD 파일명을 NFC로 변경
    @discardableResult
    func renameToNFC(at path: String) -> RenameResult {
        let filename = (path as NSString).lastPathComponent
        
        // NFD 확인
        guard UnicodeNormalizer.isNFD(filename) else {
            return .skipped(reason: .notNFD)
        }
        
        // 정책 확인
        guard pathPolicy.canRename(path) else {
            recordHistory(path: path, filename: filename, newFilename: filename, result: .skipped, reason: "제외 규칙")
            return .skipped(reason: .excluded)
        }
        
        // NFC 파일명 생성
        let nfcFilename = UnicodeNormalizer.toNFC(filename)
        
        let directory = (path as NSString).deletingLastPathComponent
        let newPath = (directory as NSString).appendingPathComponent(nfcFilename)

        // rename은 부모 디렉토리 쓰기 권한이 필요. 소유자(read-only) 폴더는 u+w를 임시 부여 후 원복.
        var restoredDirectoryPermissions: NSNumber?
        do {
            restoredDirectoryPermissions = try makeDirectoryWritableIfNeeded(directory)
        } catch {
            recordHistory(path: path, filename: filename, newFilename: nfcFilename, result: .skipped, reason: SkipReason.permissionDenied.description)
            return .skipped(reason: .permissionDenied)
        }
        defer {
            if let original = restoredDirectoryPermissions {
                try? FileManager.default.setAttributes([.posixPermissions: original.intValue], ofItemAtPath: directory)
            }
        }

        if !FileManager.default.isWritableFile(atPath: directory) {
            recordHistory(path: path, filename: filename, newFilename: nfcFilename, result: .skipped, reason: SkipReason.permissionDenied.description)
            return .skipped(reason: .permissionDenied)
        }
        
        // 대상 파일 존재 확인
        if FileManager.default.fileExists(atPath: newPath) {
            // Canonical-equivalent paths can refer to the same file.
            if !isSameFile(path, newPath) {
                recordHistory(path: path, filename: filename, newFilename: nfcFilename, result: .conflict, reason: "대상 파일 존재")
                return .skipped(reason: .targetExists)
            }
        }
        
        // 원본 파일 존재 확인
        guard FileManager.default.fileExists(atPath: path) else {
            return .skipped(reason: .fileNotFound)
        }
        
        // 드라이 런 모드
        if dryRun {
            return .success(oldPath: path, newPath: newPath)
        }
        
        // 실제 이름 변경
        do {
            try renameItem(atPath: path, toPath: newPath)
            recordHistory(path: path, filename: filename, newFilename: nfcFilename, result: .success, reason: nil)
            return .success(oldPath: path, newPath: newPath)
        } catch {
            if isPermissionDenied(error) {
                recordHistory(path: path, filename: filename, newFilename: nfcFilename, result: .skipped, reason: SkipReason.permissionDenied.description)
                return .skipped(reason: .permissionDenied)
            }

            recordHistory(path: path, filename: filename, newFilename: nfcFilename, result: .failed, reason: error.localizedDescription)
            return .failed(error: error)
        }
    }
    
    /// URL 기반 이름 변경
    @discardableResult
    func renameToNFC(at url: URL) -> RenameResult {
        return renameToNFC(at: url.path)
    }
    
    // MARK: - 배치 이름 변경
    
    /// 여러 파일 일괄 이름 변경
    func batchRename(_ paths: [String]) -> [(path: String, result: RenameResult)] {
        return paths.map { path in
            (path, renameToNFC(at: path))
        }
    }
    
    // MARK: - 유틸리티
    
    /// 이름 변경 미리보기
    func preview(at path: String) -> (original: String, nfc: String, canRename: Bool, skipReason: SkipReason?) {
        let filename = (path as NSString).lastPathComponent
        let nfcFilename = UnicodeNormalizer.toNFC(filename)
        
        if !UnicodeNormalizer.isNFD(filename) {
            return (filename, nfcFilename, false, .notNFD)
        }
        
        if !pathPolicy.canRename(path) {
            return (filename, nfcFilename, false, .excluded)
        }
        
        let directory = (path as NSString).deletingLastPathComponent
        let newPath = (directory as NSString).appendingPathComponent(nfcFilename)
        
        if FileManager.default.fileExists(atPath: newPath), !isSameFile(path, newPath) {
            return (filename, nfcFilename, false, .targetExists)
        }
        
        if !FileManager.default.fileExists(atPath: path) {
            return (filename, nfcFilename, false, .fileNotFound)
        }
        
        return (filename, nfcFilename, true, nil)
    }

    // MARK: - Low-level rename

    private func renameItem(atPath oldPath: String, toPath newPath: String) throws {
        // Prefer POSIX rename(2).
        if Darwin.rename(oldPath, newPath) == 0 {
            return
        }

        // Cross-device moves
        let code = errno
        if code == EXDEV {
            try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
            return
        }

        if let posix = POSIXErrorCode(rawValue: code) {
            throw POSIXError(posix)
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func makeDirectoryWritableIfNeeded(_ directory: String) throws -> NSNumber? {
        guard !FileManager.default.isWritableFile(atPath: directory) else { return nil }

        let attrs = try FileManager.default.attributesOfItem(atPath: directory)

        // 소유자만 자동 권한 변경 (다른 사용자/시스템 경로는 건드리지 않음)
        if let ownerID = attrs[.ownerAccountID] as? NSNumber {
            guard ownerID.intValue == Int(getuid()) else { return nil }
        } else {
            return nil
        }

        guard let perms = attrs[.posixPermissions] as? NSNumber else { return nil }
        let current = perms.intValue
        let desired = current | Int(S_IWUSR)
        guard desired != current else { return nil }

        try FileManager.default.setAttributes([.posixPermissions: desired], ofItemAtPath: directory)
        return perms
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        if let posix = error as? POSIXError {
            switch posix.code {
            case .EACCES, .EPERM:
                return true
            default:
                return false
            }
        }

        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return ns.code == Int(EACCES) || ns.code == Int(EPERM)
        }
        if ns.domain == NSCocoaErrorDomain {
            return ns.code == CocoaError.fileWriteNoPermission.rawValue
                || ns.code == CocoaError.fileReadNoPermission.rawValue
        }
        return false
    }

    private func isSameFile(_ a: String, _ b: String) -> Bool {
        do {
            let attrsA = try FileManager.default.attributesOfItem(atPath: a)
            let attrsB = try FileManager.default.attributesOfItem(atPath: b)

            let inodeA = attrsA[.systemFileNumber] as? NSNumber
            let inodeB = attrsB[.systemFileNumber] as? NSNumber
            guard let inodeA, let inodeB else { return false }
            if inodeA != inodeB { return false }

            // 가능하면 device number도 같이 비교
            if let devA = attrsA[.systemNumber] as? NSNumber,
               let devB = attrsB[.systemNumber] as? NSNumber {
                return devA == devB
            }

            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Private
    
    private func recordHistory(
        path: String,
        filename: String,
        newFilename: String,
        result: RenameResultType,
        reason: String?
    ) {
        try? historyRepository?.add(
            originalPath: path,
            originalFilename: filename,
            newFilename: newFilename,
            result: result,
            errorMessage: reason
        )
    }
}
