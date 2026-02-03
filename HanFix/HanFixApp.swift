//
//  HanFixApp.swift
//  HanFix
//
//  NFD → NFC 파일명 자동 변환 메뉴바 앱
//

import SwiftUI

@main
struct HanFixApp: App {
    /// 앱 상태
    @State private var appState = AppState.shared
    
    /// 앱 델리게이트
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // 메뉴바 아이콘
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Label("HanFix", systemImage: appState.statusIconName)
        }
        .menuBarExtraStyle(.window)

        // 독립 창들: 메뉴 창이 닫혀도 유지되도록 분리
        WindowGroup("설정", id: "settings") {
            SettingsView()
                .environment(appState)
        }

        WindowGroup("수동 변환", id: "manual-fix") {
            ManualFixView()
                .environment(appState)
        }

        WindowGroup("최근 작업", id: "history") {
            HistoryView()
                .environment(appState)
        }

        WindowGroup("권한 설정", id: "onboarding") {
            FullDiskAccessOnboardingView()
                .environment(appState)
        }
    }
}

// MARK: - App Delegate

/// 앱 델리게이트 - 초기화 및 생명주기 관리
final class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 서비스 코디네이터 초기화
        do {
            try ServiceCoordinator.shared.initialize()
        } catch {
            print("서비스 초기화 실패: \(error.localizedDescription)")
            AppState.shared.setError("서비스 초기화 실패: \(error.localizedDescription)")
        }
        
        // 권한 확인
        PermissionManager.shared.checkFullDiskAccess()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 서비스 정리
        ServiceCoordinator.shared.stopServices()
    }
}
