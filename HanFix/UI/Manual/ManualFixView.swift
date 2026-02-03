//
//  ManualFixView.swift
//  HanFix
//
//  수동 변환 화면 - NFD 파일 목록 및 선택 변환
//

import SwiftUI

/// 수동 변환 뷰
struct ManualFixView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    
    @State private var nfdFiles: [IndexedFile] = []
    @State private var selectedFiles: Set<Int64> = []
    @State private var isLoading = true
    @State private var isConverting = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 툴바
                HStack {
                    // 선택 컨트롤
                    Button(action: selectAll) {
                        Text("모두 선택")
                    }
                    .disabled(nfdFiles.isEmpty)
                    
                    Button(action: deselectAll) {
                        Text("선택 해제")
                    }
                    .disabled(selectedFiles.isEmpty)
                    
                    Spacer()
                    
                    // 선택된 파일 수
                    Text("\(selectedFiles.count)/\(nfdFiles.count)개 선택")
                        .foregroundStyle(.secondary)
                }
                .padding()
                
                Divider()
                
                // 파일 목록
                if isLoading {
                    ProgressView("로딩 중...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if nfdFiles.isEmpty {
                    ContentUnavailableView(
                        "NFD 파일 없음",
                        systemImage: "checkmark.circle",
                        description: Text("변환이 필요한 NFD 파일이 없습니다.")
                    )
                } else {
                    List(nfdFiles, selection: $selectedFiles) { file in
                        NFDFileRow(file: file, isSelected: selectedFiles.contains(file.id))
                            .tag(file.id)
                    }
                    .listStyle(.inset)
                }
                
                // 에러 메시지
                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding()
                }
                
                Divider()
                
                // 하단 액션 바
                HStack {
                    // 새로고침
                    Button(action: loadFiles) {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                    
                    Spacer()
                    
                    // 변환 버튼
                    Button(action: convertSelected) {
                        if isConverting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("선택 변환", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFiles.isEmpty || isConverting)
                    
                    // 전체 변환
                    Button(action: convertAll) {
                        Label("전체 변환", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .disabled(nfdFiles.isEmpty || isConverting)
                }
                .padding()
            }
            .navigationTitle("수동 변환")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            loadFiles()
        }
    }
    
    // MARK: - Actions
    
    private func loadFiles() {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .utility).async {
            do {
                let files = try ServiceCoordinator.shared.getNFDFiles(limit: 500)
                DispatchQueue.main.async {
                    nfdFiles = files
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
    
    private func selectAll() {
        selectedFiles = Set(nfdFiles.map { $0.id })
    }
    
    private func deselectAll() {
        selectedFiles.removeAll()
    }
    
    private func convertSelected() {
        isConverting = true
        
        let paths = nfdFiles
            .filter { selectedFiles.contains($0.id) }
            .map { $0.path }
        
        DispatchQueue.global(qos: .utility).async {
            let results = ServiceCoordinator.shared.convertFiles(paths)
            let successCount = results.filter { $0.result.isSuccess }.count

            DispatchQueue.main.async {
                isConverting = false
                selectedFiles.removeAll()
                loadFiles()

                if successCount > 0 {
                    // 성공 알림 (선택적)
                }
            }
        }
    }
    
    private func convertAll() {
        isConverting = true

        DispatchQueue.global(qos: .utility).async {
            ServiceCoordinator.shared.convertAllNFDFiles()

            DispatchQueue.main.async {
                isConverting = false
                loadFiles()
            }
        }
    }
}

// MARK: - NFD 파일 행

struct NFDFileRow: View {
    let file: IndexedFile
    let isSelected: Bool
    
    var body: some View {
        let original = file.isNFD ? UnicodeNormalizer.renderDecomposedHangul(file.filename) : file.filename

        HStack {
            // 선택 체크박스 (시각적)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
            
            // 파일 아이콘
            Image(systemName: file.fileType == "directory" ? "folder" : "doc")
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                // 파일명
                HStack(spacing: 4) {
                    Text(original)
                        .font(.body)
                        .lineLimit(1)
                    
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(file.filenameNFC)
                        .font(.body)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
                
                // 경로
                Text(file.directoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            // 파일 크기
            if let size = file.size {
                Text(formatFileSize(size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Preview

#Preview {
    ManualFixView()
        .environment(AppState.shared)
}
