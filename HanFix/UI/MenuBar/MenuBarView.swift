//
//  MenuBarView.swift
//  HanFix
//
//  메뉴바 UI (RunCat 스타일)
//

import SwiftUI

/// 메뉴바 컨텐츠 뷰
struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 상태 헤더
            StatusHeaderView()
            
            Divider()
                .padding(.vertical, 4)
            
            // 서비스 토글
            ServiceToggleRow()
            
            // 모드 선택
            ModeSelectionRow()
            
            Divider()
                .padding(.vertical, 4)
            
            // 액션 버튼들
            ActionButtonsSection(
                onOpenManualFix: { openWindow(id: "manual-fix") },
                onOpenHistory: { openWindow(id: "history") },
                onOpenSettings: { openWindow(id: "settings") }
            )
            
            Divider()
                .padding(.vertical, 4)
            
            // 종료 버튼
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("종료", systemImage: "power")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .padding(.vertical, 8)
        .frame(width: 280)
        .onAppear {
            // FDA 권한 확인 (메뉴 열릴 때마다 최신 상태로 갱신)
            PermissionManager.shared.checkFullDiskAccess()
            if !PermissionManager.shared.hasFullDiskAccess {
                openWindow(id: "onboarding")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 사용자가 시스템 설정에서 권한을 켠 뒤 돌아오면 즉시 반영
            PermissionManager.shared.checkFullDiskAccess()
            if !PermissionManager.shared.hasFullDiskAccess {
                openWindow(id: "onboarding")
            }
        }
    }
}

// MARK: - 상태 헤더

struct StatusHeaderView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        HStack {
            // 상태 아이콘
            Image(systemName: appState.statusIconName)
                .font(.title2)
                .foregroundStyle(statusColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("HanFix")
                    .font(.headline)
                
                Text(appState.statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // 통계 뱃지
            if appState.isServiceEnabled {
                StatsBadge()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private var statusColor: Color {
        if !appState.isServiceEnabled {
            return .secondary
        }
        if appState.pendingNFDCount > 0 {
            return .orange
        }
        return .green
    }
}

// MARK: - 통계 뱃지

struct StatsBadge: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        HStack(spacing: 8) {
            // 인덱싱된 파일 수
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(appState.indexedFileCount)")
                    .font(.caption.monospacedDigit())
                    .fontWeight(.medium)
                Text("인덱스")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            // NFD 파일 수
            if appState.pendingNFDCount > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(appState.pendingNFDCount)")
                        .font(.caption.monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                    Text("NFD")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 서비스 토글

struct ServiceToggleRow: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var state = appState
        
        Toggle(isOn: $state.isServiceEnabled) {
            Label("서비스 활성화", systemImage: "bolt.fill")
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 모드 선택

struct ModeSelectionRow: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var state = appState
        
        HStack {
            Text("모드")
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Picker("", selection: $state.operationMode) {
                ForEach(OperationMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 액션 버튼 섹션

struct ActionButtonsSection: View {
    let onOpenManualFix: () -> Void
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void
    
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 수동 변환 버튼
            Button(action: onOpenManualFix) {
                HStack {
                    Label("수동 변환", systemImage: "list.bullet")
                    Spacer()
                    if appState.pendingNFDCount > 0 {
                        Text("\(appState.pendingNFDCount)")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            // 히스토리 버튼
            Button(action: onOpenHistory) {
                Label("최근 작업", systemImage: "clock")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            
            // 설정 버튼
            Button(action: onOpenSettings) {
                Label("설정", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Preview

#Preview {
    MenuBarView()
        .environment(AppState.shared)
}
