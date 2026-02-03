//
//  PermissionManager.swift
//  HanFix
//
//  Full Disk Access 권한 관리
//

import SwiftUI
import AppKit
import Foundation

/// Full Disk Access 권한 상태 및 관리
@Observable
final class PermissionManager {
    
    /// 싱글톤 인스턴스
    static let shared = PermissionManager()
    
    /// FDA 권한 상태
    private(set) var hasFullDiskAccess: Bool = false
    
    /// 권한 확인 완료 여부
    private(set) var hasCheckedPermission: Bool = false
    
    private init() {
        checkFullDiskAccess()
    }
    
    // MARK: - 권한 확인
    
    /// Full Disk Access 권한 확인
    /// - Note: 시스템 보호 디렉토리에 접근 가능한지 테스트하여 권한 유무 판단
    func checkFullDiskAccess() {
        // Heuristic check (no public API): try reading/listing protected paths.

        let candidateFiles = [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Messages/chat.db"
        ]

        let candidateDirectories = [
            NSHomeDirectory() + "/Library/Containers/com.apple.stocks",
            NSHomeDirectory() + "/Library/Safari",
            NSHomeDirectory() + "/Library/Mail",
            NSHomeDirectory() + "/Library/Messages",
            "/Library/Application Support/com.apple.TCC"
        ]

        hasFullDiskAccess = candidateFiles.contains(where: canReadFile) ||
            candidateDirectories.contains(where: canListDirectory)

        hasCheckedPermission = true
    }

    private func canReadFile(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
            return true
        } catch {
            return false
        }
    }

    private func canListDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - 시스템 환경설정 열기
    
    /// 시스템 환경설정 > 개인 정보 보호 > Full Disk Access 열기
    func openFullDiskAccessSettings() {
        // macOS 13+ (Ventura 이상)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// 시스템 환경설정 > 개인 정보 보호 열기 (구버전 호환)
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - FDA 온보딩 뷰

/// Full Disk Access 권한 요청 온보딩 뷰
struct FullDiskAccessOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var permissionManager = PermissionManager.shared
    
    var body: some View {
        VStack(spacing: 20) {
            // 아이콘
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
            
            // 제목
            Text("전체 디스크 접근 권한 필요")
                .font(.title2)
                .fontWeight(.bold)
            
            // 설명
            VStack(alignment: .leading, spacing: 12) {
                PermissionExplanationRow(
                    icon: "magnifyingglass",
                    text: "파일 이름을 검색하고 인덱싱합니다"
                )
                PermissionExplanationRow(
                    icon: "character.ko",
                    text: "한글 자소 분리(NFD) 파일을 감지합니다"
                )
                PermissionExplanationRow(
                    icon: "arrow.triangle.2.circlepath",
                    text: "파일 이름을 자동으로 정규화합니다"
                )
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // 권한 상태
            HStack {
                Circle()
                    .fill(permissionManager.hasFullDiskAccess ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(permissionManager.hasFullDiskAccess ? "권한 허용됨" : "권한 필요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // 버튼들
            VStack(spacing: 12) {
                Button(action: {
                    permissionManager.openFullDiskAccessSettings()
                }) {
                    Label("시스템 환경설정 열기", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: {
                    permissionManager.checkFullDiskAccess()
                    if permissionManager.hasFullDiskAccess {
                        dismiss()
                    }
                }) {
                    Label("권한 다시 확인", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }) {
                    Label("현재 앱 위치 열기", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button("다음에 설정하기") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            
            // 안내 텍스트
            Text("시스템 환경설정 > 개인 정보 보호 및 보안 > 전체 디스크 접근 권한에서 HanFix를 활성화해주세요.\n권한 변경 후에는 앱을 재시작해야 적용될 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 400, height: 500)
        .onAppear {
            permissionManager.checkFullDiskAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionManager.checkFullDiskAccess()
            if permissionManager.hasFullDiskAccess {
                dismiss()
            }
        }
    }
}

/// 권한 설명 행
private struct PermissionExplanationRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.body)
        }
    }
}

// MARK: - Preview

#Preview {
    FullDiskAccessOnboardingView()
}
