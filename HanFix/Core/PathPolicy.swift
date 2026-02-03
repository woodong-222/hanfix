//
//  PathPolicy.swift
//  HanFix
//
//  경로 제외/포함 정책 관리
//

import Foundation

/// 경로 정책 관리자
final class PathPolicy {
    
    /// 싱글톤 인스턴스
    static let shared = PathPolicy()
    
    // MARK: - 감시 범위
    
    enum WatchScope: String, CaseIterable {
        case fullDisk = "fullDisk"
        case homeDirectory = "home"
        case customPaths = "custom"
    }
    
    // MARK: - 기본 제외 설정
    
    static let defaultExcludedExtensions: Set<String> = [
        "app", "framework", "bundle", "pkg", "kext", "plugin"
    ]
    
    static let systemExcludedPaths: Set<String> = [
        "/System", "/Library", "/usr", "/bin", "/sbin",
        "/private", "/var", "/tmp", "/cores", "/opt"
    ]
    
    // MARK: - 설정
    
    var watchScope: WatchScope = .homeDirectory
    var customWatchPaths: [String] = []
    var userExcludedPaths: Set<String> = []
    var excludedExtensions: Set<String> = PathPolicy.defaultExcludedExtensions
    var excludeHiddenFiles: Bool = true
    var excludeSymlinks: Bool = true
    var includeBundleContents: Bool = false
    
    private init() {
        loadSettings()
    }
    
    // MARK: - 경로 확인
    
    /// 경로가 감시 대상인지 확인
    func shouldWatch(_ path: String) -> Bool {
        // 시스템 경로 제외
        if isSystemPath(path) { return false }
        
        // 사용자 제외 경로 확인
        if isUserExcludedPath(path) { return false }
        
        // 숨김 파일 확인
        if excludeHiddenFiles && isHiddenPath(path) { return false }
        
        // 번들/패키지 확인
        if !includeBundleContents && isInsideBundle(path) { return false }
        
        // 심볼릭 링크 확인
        if excludeSymlinks && isSymlink(path) { return false }
        
        // 감시 범위 확인
        return isInWatchScope(path)
    }
    
    /// 경로가 이름 변경 대상인지 확인
    func canRename(_ path: String) -> Bool {
        // 기본 감시 대상 확인
        guard shouldWatch(path) else { return false }
        
        // 번들 자체는 이름 변경 불가
        if isBundleRoot(path) { return false }
        
        return true
    }
    
    /// 경로가 제외 규칙에 해당하는지 확인
    func isExcluded(_ url: URL, fileManager: FileManager = .default) -> Bool {
        return !shouldWatch(url.path)
    }
    
    // MARK: - 경로 분류
    
    func isSystemPath(_ path: String) -> Bool {
        for systemPath in Self.systemExcludedPaths {
            if path == systemPath || path.hasPrefix(systemPath + "/") {
                return true
            }
        }
        return false
    }
    
    func isUserExcludedPath(_ path: String) -> Bool {
        for excludedPath in userExcludedPaths {
            if path == excludedPath || path.hasPrefix(excludedPath + "/") {
                return true
            }
        }
        return false
    }
    
    func isHiddenPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent
        return filename.hasPrefix(".")
    }
    
    func isBundleRoot(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return excludedExtensions.contains(ext)
    }
    
    func isInsideBundle(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        for component in components.dropLast() {
            let ext = (String(component) as NSString).pathExtension.lowercased()
            if excludedExtensions.contains(ext) {
                return true
            }
        }
        return false
    }
    
    func isSymlink(_ path: String) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            if let fileType = attrs[.type] as? FileAttributeType {
                return fileType == .typeSymbolicLink
            }
        } catch {
            return false
        }
        return false
    }
    
    func isInWatchScope(_ path: String) -> Bool {
        switch watchScope {
        case .fullDisk:
            return true
        case .homeDirectory:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.hasPrefix(home)
        case .customPaths:
            for watchPath in customWatchPaths {
                if path == watchPath || path.hasPrefix(watchPath + "/") {
                    return true
                }
            }
            return false
        }
    }
    
    // MARK: - 감시 루트 경로
    
    func getWatchRoots() -> [String] {
        switch watchScope {
        case .fullDisk:
            return ["/"]
        case .homeDirectory:
            return [FileManager.default.homeDirectoryForCurrentUser.path]
        case .customPaths:
            return customWatchPaths
        }
    }
    
    // MARK: - 설정 저장/로드
    
    private func loadSettings() {
        let defaults = UserDefaults.standard
        
        if let scopeRaw = defaults.string(forKey: "PathPolicy.watchScope"),
           let scope = WatchScope(rawValue: scopeRaw) {
            watchScope = scope
        }
        
        customWatchPaths = defaults.stringArray(forKey: "PathPolicy.customWatchPaths") ?? []
        userExcludedPaths = Set(defaults.stringArray(forKey: "PathPolicy.userExcludedPaths") ?? [])
        excludeHiddenFiles = defaults.object(forKey: "PathPolicy.excludeHiddenFiles") as? Bool ?? true
        excludeSymlinks = defaults.object(forKey: "PathPolicy.excludeSymlinks") as? Bool ?? true
        includeBundleContents = defaults.bool(forKey: "PathPolicy.includeBundleContents")
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        
        defaults.set(watchScope.rawValue, forKey: "PathPolicy.watchScope")
        defaults.set(customWatchPaths, forKey: "PathPolicy.customWatchPaths")
        defaults.set(Array(userExcludedPaths), forKey: "PathPolicy.userExcludedPaths")
        defaults.set(excludeHiddenFiles, forKey: "PathPolicy.excludeHiddenFiles")
        defaults.set(excludeSymlinks, forKey: "PathPolicy.excludeSymlinks")
        defaults.set(includeBundleContents, forKey: "PathPolicy.includeBundleContents")
    }
}
