//
//  ServiceCoordinator.swift
//  HanFix
//
//  서비스 오케스트레이션 - 인덱서, 와처, 리네임 엔진 조율
//

import Foundation

/// 서비스 코디네이터 - 앱의 핵심 서비스 관리
final class ServiceCoordinator {
    
    /// 싱글톤 인스턴스
    static let shared = ServiceCoordinator()
    
    /// 앱 상태
    private let appState: AppState
    
    /// 데이터베이스
    private let database: Database
    
    /// 인덱서
    private let indexer: Indexer
    
    /// 파일 시스템 감시자
    private let eventWatcher: EventWatcher
    
    /// 이름 변경 엔진
    private let renameEngine: RenameEngine
    
    /// 파일 저장소
    private let fileRepository: FileIndexRepository
    
    /// 히스토리 저장소
    private let historyRepository: RenameHistoryRepository
    
    /// 초기화 완료 여부
    private(set) var isInitialized: Bool = false
    
    private init() {
        appState = AppState.shared
        database = Database.shared
        indexer = Indexer.shared
        eventWatcher = EventWatcher.shared
        renameEngine = RenameEngine.shared
        fileRepository = FileIndexRepository(database: database)
        historyRepository = RenameHistoryRepository(database: database)
    }
    
    // MARK: - 초기화
    
    /// 서비스 초기화
    func initialize() throws {
        guard !isInitialized else { return }
        
        // 1. 데이터베이스 열기
        try database.open()
        
        // 2. 저장소 연결
        indexer.setFileRepository(fileRepository)
        renameEngine.setHistoryRepository(historyRepository)
        eventWatcher.setIndexer(indexer)
        
        // 3. 이벤트 핸들러 설정
        setupEventHandlers()
        
        // 4. 앱 상태 연결
        appState.onServiceStateChanged = { [weak self] enabled in
            if enabled {
                self?.startServices()
            } else {
                self?.stopServices()
            }
        }
        
        // 5. 통계 새로고침
        appState.refreshStats()
        
        isInitialized = true
        
        // 6. 이전 설정에 따라 서비스 시작
        if appState.isServiceEnabled {
            startServices()
        }
    }
    
    // MARK: - 서비스 제어
    
    /// 서비스 시작
    func startServices() {
        // 인덱서 시작
        if indexer.state == .idle || indexer.state == .completed || indexer.state == .cancelled {
            indexer.start()
        }
        
        // 감시자 시작
        let watchPaths = PathPolicy.shared.getWatchRoots()
        eventWatcher.start(paths: watchPaths)
    }
    
    /// 서비스 중지
    func stopServices() {
        indexer.stop()
        eventWatcher.stop()
    }
    
    /// 인덱싱 재시작
    func restartIndexing() {
        indexer.stop()
        
        // 잠시 대기 후 재시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.indexer.start()
        }
    }
    
    // MARK: - 이벤트 핸들러
    
    private func setupEventHandlers() {
        // 인덱싱 진행 상황
        indexer.onProgressUpdate = { [weak self] progress in
            self?.appState.updateIndexingProgress(progress)
        }
        
        // 인덱싱 완료
        indexer.onComplete = { [weak self] totalFiles, nfdFiles in
            self?.appState.indexedFileCount = totalFiles
            self?.appState.pendingNFDCount = nfdFiles
            self?.appState.indexingProgress = nil

            // 자동 모드라면: 초기 스캔에서 발견된 기존 NFD 파일도 바로 변환
            guard let self = self else { return }
            guard self.appState.operationMode == .automatic else { return }
            guard nfdFiles > 0 else { return }

            DispatchQueue.global(qos: .utility).async {
                self.convertAllNFDFiles()
            }
        }
        
        // NFD 파일 감지
        eventWatcher.onNFDDetected = { [weak self] path in
            self?.handleNFDDetected(at: path)
        }
    }
    
    private func handleNFDDetected(at path: String) {
        switch appState.operationMode {
        case .automatic:
            // 자동 모드: 즉시 변환
            let result = renameEngine.renameToNFC(at: path)
            
            if case let .success(oldPath, newPath) = result {
                indexer.updatePath(from: oldPath, to: newPath)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.appState.todayConvertedCount += 1
                    self.appState.pendingNFDCount = max(0, self.appState.pendingNFDCount - 1)
                }
            }
            
        case .manual:
            // 수동 모드: 대기열에 추가 (이미 인덱싱에서 처리됨)
            DispatchQueue.main.async { [weak self] in
                self?.appState.pendingNFDCount += 1
            }
        }
    }
    
    // MARK: - 수동 변환
    
    /// 수동 모드에서 선택한 파일들 변환
    func convertFiles(_ paths: [String]) -> [(path: String, result: RenameResult)] {
        let results = renameEngine.batchRename(paths)

        // DB 경로 업데이트 (성공한 건만)
        for (_, result) in results {
            if case let .success(oldPath, newPath) = result {
                indexer.updatePath(from: oldPath, to: newPath)
            }
        }
        
        // 통계 업데이트 (UI 스레드에서)
        let successCount = results.filter { $0.result.isSuccess }.count
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.appState.todayConvertedCount += successCount
            self.appState.pendingNFDCount = max(0, self.appState.pendingNFDCount - successCount)
        }
        
        return results
    }
    
    /// 모든 NFD 파일 변환
    func convertAllNFDFiles() {
        do {
            // 남은 NFD가 없어질 때까지 반복 (DB는 성공 시 updatePath로 즉시 갱신됨)
            var safetyCounter = 0
            while safetyCounter < 10_000 {
                let nfdFiles = try fileRepository.findNFDFiles(limit: 200, offset: 0)
                if nfdFiles.isEmpty { break }
                let paths = nfdFiles.map { $0.path }
                let results = convertFiles(paths)

                let successCount = results.filter { $0.result.isSuccess }.count
                if successCount == 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.appState.setError("권한/충돌 등의 이유로 변환할 수 없는 파일이 남아 있습니다. (예: 폴더가 읽기 전용)")
                    }
                    break
                }
                safetyCounter += 1
            }
            
            // 통계 새로고침
            appState.refreshStats()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.appState.setError("NFD 파일 조회 실패: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - 유틸리티
    
    /// NFD 파일 목록 가져오기
    func getNFDFiles(limit: Int = 100) throws -> [IndexedFile] {
        return try fileRepository.findNFDFiles(limit: limit)
    }
    
    /// 최근 히스토리 가져오기
    func getRecentHistory(limit: Int = 50) throws -> [RenameHistoryItem] {
        return try historyRepository.getRecent(limit: limit)
    }
    
    /// 오래된 히스토리 정리
    func cleanupOldHistory(olderThanDays days: Int = 30) {
        try? historyRepository.deleteOlderThan(days: days)
    }

    func cleanupOldHistoryReturningCount(olderThanDays days: Int = 30) -> Int {
        (try? historyRepository.deleteOlderThanReturningCount(days: days)) ?? 0
    }

    func deleteAllHistory() -> Int {
        (try? historyRepository.deleteAll()) ?? 0
    }
}
