//
//  HistoryView.swift
//  HanFix
//
//  최근 작업 히스토리 화면
//

import SwiftUI

/// 히스토리 뷰
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    
    @State private var historyItems: [RenameHistoryItem] = []
    @State private var isLoading = true
    @State private var selectedFilter: HistoryFilter = .all
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 필터 탭
                Picker("필터", selection: $selectedFilter) {
                    ForEach(HistoryFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                Divider()
                
                // 히스토리 목록
                if isLoading {
                    ProgressView("로딩 중...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if historyItems.isEmpty {
                    ContentUnavailableView(
                        "히스토리 없음",
                        systemImage: "clock.badge.questionmark",
                        description: Text("아직 변환 기록이 없습니다.")
                    )
                } else {
                    List(filteredItems) { item in
                        HistoryItemRow(item: item)
                    }
                    .listStyle(.inset)
                }
                
                Divider()
                
                // 하단 통계
                HStack {
                    TodayStatsView()
                    
                    Spacer()
                    
                    Button("히스토리 정리") {
                        cleanupHistory()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("최근 작업")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button(action: loadHistory) {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            loadHistory()
        }
    }
    
    // MARK: - Computed Properties
    
    private var filteredItems: [RenameHistoryItem] {
        switch selectedFilter {
        case .all:
            return historyItems
        case .success:
            return historyItems.filter { $0.result == .success }
        case .failed:
            return historyItems.filter { $0.result == .failed || $0.result == .conflict }
        case .skipped:
            return historyItems.filter { $0.result == .skipped }
        }
    }
    
    // MARK: - Actions
    
    private func loadHistory() {
        isLoading = true
        
        Task {
            do {
                let items = try ServiceCoordinator.shared.getRecentHistory(limit: 100)
                await MainActor.run {
                    historyItems = items
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
    
    private func cleanupHistory() {
        ServiceCoordinator.shared.cleanupOldHistory(olderThanDays: 7)
        loadHistory()
    }
}

// MARK: - 필터 타입

enum HistoryFilter: CaseIterable {
    case all
    case success
    case failed
    case skipped
    
    var displayName: String {
        switch self {
        case .all: return "전체"
        case .success: return "성공"
        case .failed: return "실패"
        case .skipped: return "건너뜀"
        }
    }
}

// MARK: - 히스토리 항목 행

struct HistoryItemRow: View {
    let item: RenameHistoryItem
    
    var body: some View {
        HStack {
            // 결과 아이콘
            Image(systemName: item.resultIcon)
                .font(.title2)
                .foregroundStyle(resultColor)
            
            VStack(alignment: .leading, spacing: 4) {
                // 파일명 변환
                HStack(spacing: 4) {
                    Text(item.originalFilename)
                        .font(.body)
                        .lineLimit(1)
                    
                    if item.result == .success {
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text(item.newFilename)
                            .font(.body)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    }
                }
                
                // 경로 및 결과
                HStack {
                    Text((item.originalPath as NSString).deletingLastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Text(item.resultDescription)
                        .font(.caption)
                        .foregroundStyle(resultColor)
                }
                
                // 에러 메시지 (있는 경우)
                if let error = item.errorMessage, item.result != .success {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            // 시간
            Text(formatTime(item.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private var resultColor: Color {
        switch item.result {
        case .success: return .green
        case .skipped: return .gray
        case .conflict: return .orange
        case .failed: return .red
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 오늘 통계 뷰

struct TodayStatsView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        HStack(spacing: 16) {
            StatItem(title: "오늘 변환", value: appState.todayConvertedCount, color: .green)
        }
    }
}

struct StatItem: View {
    let title: String
    let value: Int
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)개")
                .font(.headline)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Preview

#Preview {
    HistoryView()
        .environment(AppState.shared)
}
