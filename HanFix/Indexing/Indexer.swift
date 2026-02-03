//
//  Indexer.swift
//  HanFix
//
//  파일 시스템 인덱서 - 디스크 스캔 및 DB 저장
//

import Foundation

/// 인덱싱 상태
enum IndexingState {
    case idle           // 대기 중
    case scanning       // 스캔 중
    case paused         // 일시 정지
    case completed      // 완료
    case cancelled      // 취소됨
}

/// 인덱싱 진행 상황
struct IndexingProgress {
    let scannedFiles: Int
    let nfdFiles: Int
    let currentPath: String?
    let startTime: Date
    let state: IndexingState
    
    var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
    
    var filesPerSecond: Double {
        guard elapsedTime > 0 else { return 0 }
        return Double(scannedFiles) / elapsedTime
    }
}

/// 파일 시스템 인덱서
final class Indexer {
    
    /// 싱글톤 인스턴스
    static let shared = Indexer()
    
    /// 인덱싱 상태
    private(set) var state: IndexingState = .idle
    
    /// 진행 상황
    private(set) var progress: IndexingProgress?
    
    /// 배치 크기 (한 번에 DB에 저장할 파일 수)
    var batchSize: Int = 500
    
    /// 정책 관리자
    private let pathPolicy: PathPolicy
    
    /// 파일 저장소
    private var fileRepository: FileIndexRepository?
    
    /// 취소 플래그
    private var isCancelled: Bool = false
    
    /// 진행 상황 콜백
    var onProgressUpdate: ((IndexingProgress) -> Void)?

    /// 진행 상황 업데이트 최소 간격 (초)
    private let progressUpdateInterval: TimeInterval = 0.25
    private var lastProgressUpdateAt: Date = .distantPast
    
    /// 완료 콜백
    var onComplete: ((Int, Int) -> Void)?  // (totalFiles, nfdFiles)
    
    /// 작업 큐 (Background QoS)
    private let workQueue = DispatchQueue(
        label: "com.hanfix.indexer",
        qos: .background,
        attributes: .concurrent
    )
    
    init(pathPolicy: PathPolicy = .shared) {
        self.pathPolicy = pathPolicy
    }
    
    /// 파일 저장소 설정
    func setFileRepository(_ repository: FileIndexRepository) {
        self.fileRepository = repository
    }
    
    // MARK: - 인덱싱 제어
    
    /// 인덱싱 시작
    func start() {
        guard state == .idle || state == .completed || state == .cancelled else {
            return
        }
        
        state = .scanning
        isCancelled = false
        
        let roots = pathPolicy.getWatchRoots()
        progress = IndexingProgress(
            scannedFiles: 0,
            nfdFiles: 0,
            currentPath: nil,
            startTime: Date(),
            state: .scanning
        )
        
        workQueue.async { [weak self] in
            self?.performIndexing(roots: roots)
        }
    }
    
    /// 인덱싱 중지
    func stop() {
        isCancelled = true
        state = .cancelled
    }
    
    /// 인덱싱 일시 정지
    func pause() {
        if state == .scanning {
            state = .paused
        }
    }
    
    /// 인덱싱 재개
    func resume() {
        if state == .paused {
            state = .scanning
        }
    }
    
    // MARK: - 인덱싱 수행
    
    private func performIndexing(roots: [String]) {
        var scannedFiles = 0
        var nfdFiles = 0
        var batch: [IndexedFile] = []

        lastProgressUpdateAt = Date()
        
        for root in roots {
            guard !isCancelled else { break }
            
            let rootURL = URL(fileURLWithPath: root)
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],  // 숨김 파일 제외
                errorHandler: nil
            )
            
            while let fileURL = enumerator?.nextObject() as? URL {
                guard !isCancelled else { break }
                
                // 일시 정지 대기
                while state == .paused && !isCancelled {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                
                let fullPath = fileURL.path
                
                // 정책 확인
                guard pathPolicy.shouldWatch(fullPath) else {
                    // 디렉토리인 경우 하위도 건너뛰기
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir),
                       isDir.boolValue {
                        enumerator?.skipDescendants()
                    }
                    continue
                }
                
                scannedFiles += 1
                
                // 파일 정보 수집
                if let indexedFile = createIndexedFile(at: fullPath) {
                    batch.append(indexedFile)
                    
                    // 디렉토리는 자동 변환 대상에서 제외 (하위 경로 DB 업데이트가 복잡해짐)
                    if indexedFile.isNFD && indexedFile.fileType != "directory" {
                        nfdFiles += 1
                    }
                }
                
                // 배치 저장
                if batch.count >= batchSize {
                    saveBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                    
                    // CPU 양보 (짧은 휴식)
                    Thread.sleep(forTimeInterval: 0.001)
                }
                
                // 진행 상황 업데이트 (100개마다)
                let now = Date()
                if now.timeIntervalSince(lastProgressUpdateAt) >= progressUpdateInterval {
                    lastProgressUpdateAt = now
                    updateProgress(scanned: scannedFiles, nfd: nfdFiles, currentPath: fullPath)
                }
            }
        }
        
        // 남은 배치 저장
        if !batch.isEmpty {
            saveBatch(batch)
        }
        
        // 완료 처리
        DispatchQueue.main.async { [weak self] in
            self?.state = self?.isCancelled == true ? .cancelled : .completed
            self?.progress = IndexingProgress(
                scannedFiles: scannedFiles,
                nfdFiles: nfdFiles,
                currentPath: nil,
                startTime: self?.progress?.startTime ?? Date(),
                state: self?.state ?? .completed
            )
            self?.onComplete?(scannedFiles, nfdFiles)
        }
    }
    
    private func createIndexedFile(at path: String) -> IndexedFile? {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent
        let nfcFilename = UnicodeNormalizer.toNFC(filename)
        let isNFD = UnicodeNormalizer.isNFD(filename)
        
        // 파일 속성 가져오기
        var fileType: String?
        var size: Int64?
        var modifiedAt: Date?
        
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            
            if let type = attrs[.type] as? FileAttributeType {
                fileType = type == .typeDirectory ? "directory" : "file"
            }
            
            size = attrs[.size] as? Int64
            modifiedAt = attrs[.modificationDate] as? Date
        } catch {
            // 속성 가져오기 실패 시에도 기본 정보는 저장
        }
        
        return IndexedFile(
            id: 0,  // DB에서 자동 생성
            path: path,
            filename: filename,
            filenameNFC: nfcFilename,
            isNFD: isNFD,
            fileType: fileType,
            size: size,
            modifiedAt: modifiedAt,
            indexedAt: Date(),
            isExcluded: false
        )
    }
    
    private func saveBatch(_ files: [IndexedFile]) {
        try? fileRepository?.batchUpsert(files)
    }
    
    private func updateProgress(scanned: Int, nfd: Int, currentPath: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let startTime = self.progress?.startTime else { return }
            
            self.progress = IndexingProgress(
                scannedFiles: scanned,
                nfdFiles: nfd,
                currentPath: currentPath,
                startTime: startTime,
                state: self.state
            )
            
            self.onProgressUpdate?(self.progress!)
        }
    }
    
    // MARK: - 증분 인덱싱
    
    /// 특정 경로만 인덱싱 (이벤트 기반 업데이트용)
    func indexPath(_ path: String) {
        guard pathPolicy.shouldWatch(path) else { return }
        
        workQueue.async { [weak self] in
            if let indexedFile = self?.createIndexedFile(at: path) {
                try? self?.fileRepository?.upsert(indexedFile)
            }
        }
    }
    
    /// 특정 경로 삭제
    func removePath(_ path: String) {
        workQueue.async { [weak self] in
            try? self?.fileRepository?.deleteByPath(path)
        }
    }
    
    /// 경로 업데이트 (이름 변경 후)
    func updatePath(from oldPath: String, to newPath: String) {
        guard pathPolicy.shouldWatch(newPath) else {
            removePath(oldPath)
            return
        }
        
        let newFilename = (newPath as NSString).lastPathComponent
        let newFilenameNFC = UnicodeNormalizer.toNFC(newFilename)
        
        workQueue.async { [weak self] in
            try? self?.fileRepository?.updatePath(
                from: oldPath,
                to: newPath,
                newFilename: newFilename,
                newFilenameNFC: newFilenameNFC
            )
        }
    }
}
