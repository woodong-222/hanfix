//
//  SettingsView.swift
//  HanFix
//
//  설정 화면
//

import SwiftUI
import UniformTypeIdentifiers

/// 설정 뷰
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    
    @State private var selectedPaths: Set<String> = []
    @State private var showPathPicker = false
    
    var body: some View {
        @Bindable var state = appState
        
        NavigationStack {
            Form {
                // 감시 범위 섹션
                Section("감시 범위") {
                    Picker("범위", selection: $state.watchScope) {
                        Text("홈 디렉토리").tag(PathPolicy.WatchScope.homeDirectory)
                        Text("전체 디스크").tag(PathPolicy.WatchScope.fullDisk)
                        Text("사용자 지정").tag(PathPolicy.WatchScope.customPaths)
                    }
                    .pickerStyle(.radioGroup)
                    
                    if state.watchScope == .customPaths {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("감시 경로:")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("추가") {
                                    showPathPicker = true
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            if state.customWatchPaths.isEmpty {
                                Text("경로를 추가해주세요")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            } else {
                                ForEach(state.customWatchPaths, id: \.self) { path in
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(path)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button(action: {
                                            state.customWatchPaths.removeAll { $0 == path }
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
                
                // 동작 모드 섹션
                Section("동작 모드") {
                    Picker("모드", selection: $state.operationMode) {
                        ForEach(OperationMode.allCases, id: \.self) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                                Text(mode.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                
                // 권한 섹션
                Section("권한") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("전체 디스크 접근 권한")
                            Text(PermissionManager.shared.hasFullDiskAccess ? "허용됨" : "필요")
                                .font(.caption)
                                .foregroundStyle(PermissionManager.shared.hasFullDiskAccess ? .green : .orange)
                        }
                        
                        Spacer()
                        
                        if !PermissionManager.shared.hasFullDiskAccess {
                            Button("설정 열기") {
                                PermissionManager.shared.openFullDiskAccessSettings()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                
                // 통계 섹션
                Section("통계") {
                    LabeledContent("인덱싱된 파일") {
                        Text("\(appState.indexedFileCount)개")
                    }
                    LabeledContent("대기 중 NFD") {
                        Text("\(appState.pendingNFDCount)개")
                    }
                    LabeledContent("오늘 변환") {
                        Text("\(appState.todayConvertedCount)개")
                    }
                }
                
                // 정보 섹션
                Section("정보") {
                    LabeledContent("버전") {
                        Text("1.0.0")
                    }
                    
                    Button("인덱싱 재시작") {
                        ServiceCoordinator.shared.restartIndexing()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 450, height: 550)
        .fileImporter(
            isPresented: $showPathPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    let path = url.path
                    if !state.customWatchPaths.contains(path) {
                        state.customWatchPaths.append(path)
                    }
                }
            case .failure:
                break
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(AppState.shared)
}
