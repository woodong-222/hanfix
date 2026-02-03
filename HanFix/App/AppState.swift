//
//  AppState.swift
//  HanFix
//
//  앱 전역 상태 관리
//

import SwiftUI

/// 동작 모드
enum OperationMode: String, CaseIterable {
    case automatic = "auto"     // 자동 모드: NFD 감지 시 즉시 변환
    case manual = "manual"      // 수동 모드: 목록에 표시, 사용자 선택 변환
    
    var displayName: String {
        switch self {
        case .automatic: return "자동"
        case .manual: return "수동"
        }
    }
    
    var description: String {
        switch self {
        case .automatic: return "NFD 파일 감지 시 자동으로 NFC로 변환합니다."
        case .manual: return "NFD 파일을 목록에 표시하고, 수동으로 선택하여 변환합니다."
        }
    }
}

/// 앱 전역 상태
@Observable
final class AppState {
    
    /// 싱글톤 인스턴스
    static let shared = AppState()
    
    // MARK: - 설정
    
    /// 서비스 활성화 여부
    var isServiceEnabled: Bool = false {
        didSet {
            saveSettings()
            onServiceStateChanged?(isServiceEnabled)
        }
    }
    
    /// 동작 모드
    var operationMode: OperationMode = .automatic {
        didSet { saveSettings() }
    }
    
    /// 감시 범위
    var watchScope: PathPolicy.WatchScope = .homeDirectory {
        didSet {
            saveSettings()
            PathPolicy.shared.watchScope = watchScope
            PathPolicy.shared.saveSettings()
        }
    }
    
    /// 사용자 지정 감시 경로
    var customWatchPaths: [String] = [] {
        didSet {
            saveSettings()
            PathPolicy.shared.customWatchPaths = customWatchPaths
            PathPolicy.shared.saveSettings()
        }
    }
    
    // MARK: - 상태 정보
    
    /// 인덱싱된 파일 수
    var indexedFileCount: Int = 0
    
    /// NFD 파일 수 (대기 중)
    var pendingNFDCount: Int = 0
    
    /// 오늘 변환한 파일 수
    var todayConvertedCount: Int = 0
    
    /// 인덱싱 진행 상황
    var indexingProgress: IndexingProgress?
    
    /// 마지막 오류 메시지
    var lastError: String?
    
    /// 서비스 상태 변경 콜백
    var onServiceStateChanged: ((Bool) -> Void)?
    
    // MARK: - 초기화
    
    private init() {
        loadSettings()
    }
    
    // MARK: - 설정 저장/로드
    
    private func loadSettings() {
        let defaults = UserDefaults.standard
        
        isServiceEnabled = defaults.bool(forKey: "AppState.isServiceEnabled")
        
        if let modeRaw = defaults.string(forKey: "AppState.operationMode"),
           let mode = OperationMode(rawValue: modeRaw) {
            operationMode = mode
        }
        
        if let scopeRaw = defaults.string(forKey: "AppState.watchScope"),
           let scope = PathPolicy.WatchScope(rawValue: scopeRaw) {
            watchScope = scope
        }
        
        customWatchPaths = defaults.stringArray(forKey: "AppState.customWatchPaths") ?? []
    }
    
    private func saveSettings() {
        let defaults = UserDefaults.standard
        
        defaults.set(isServiceEnabled, forKey: "AppState.isServiceEnabled")
        defaults.set(operationMode.rawValue, forKey: "AppState.operationMode")
        defaults.set(watchScope.rawValue, forKey: "AppState.watchScope")
        defaults.set(customWatchPaths, forKey: "AppState.customWatchPaths")
    }
    
    // MARK: - 상태 업데이트
    
    /// 통계 새로고침
    func refreshStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                let fileRepo = FileIndexRepository()
                let indexed = try fileRepo.countAllFiles()
                let pending = try fileRepo.countNFDFiles()

                let historyRepo = RenameHistoryRepository()
                let todayStats = try historyRepo.getTodayStats()

                DispatchQueue.main.async {
                    self.indexedFileCount = indexed
                    self.pendingNFDCount = pending
                    self.todayConvertedCount = todayStats.success
                    self.lastError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }
    
    /// 인덱싱 진행 상황 업데이트
    func updateIndexingProgress(_ progress: IndexingProgress) {
        indexingProgress = progress
    }
    
    /// 오류 설정
    func setError(_ error: String?) {
        lastError = error
    }
    
    /// 오류 초기화
    func clearError() {
        lastError = nil
    }
}

// MARK: - 상태 요약

extension AppState {
    /// 메뉴바에 표시할 상태 요약
    var statusSummary: String {
        if !isServiceEnabled {
            return "비활성화"
        }
        
        if let progress = indexingProgress, progress.state == .scanning {
            return "스캔 중... \(progress.scannedFiles)개"
        }
        
        if pendingNFDCount > 0 {
            return "NFD \(pendingNFDCount)개 발견"
        }
        
        return "정상 작동"
    }
    
    /// 메뉴바 아이콘 이름
    var statusIconName: String {
        if !isServiceEnabled {
            return "keyboard.badge.ellipsis"
        }
        
        if let progress = indexingProgress, progress.state == .scanning {
            return "arrow.triangle.2.circlepath"
        }
        
        if pendingNFDCount > 0 {
            return "exclamationmark.triangle"
        }
        
        return "keyboard"
    }
}
