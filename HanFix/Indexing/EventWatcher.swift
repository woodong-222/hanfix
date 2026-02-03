//
//  EventWatcher.swift
//  HanFix
//
//  FSEvents 기반 파일 시스템 감시자
//

import Foundation
import CoreServices

/// 파일 시스템 이벤트 타입
enum FileSystemEventType {
    case created       // 파일/폴더 생성
    case modified      // 수정
    case renamed       // 이름 변경
    case deleted       // 삭제
    case unknown       // 알 수 없음
}

/// 파일 시스템 이벤트
struct FileSystemEvent {
    let path: String
    let type: FileSystemEventType
    let isDirectory: Bool
    let timestamp: Date
}

/// 파일 시스템 감시자
final class EventWatcher {
    
    /// 싱글톤 인스턴스
    static let shared = EventWatcher()
    
    /// 감시 중 여부
    private(set) var isWatching: Bool = false
    
    /// FSEvents 스트림
    private var eventStream: FSEventStreamRef?
    
    /// 감시 경로
    private var watchPaths: [String] = []
    
    /// 이벤트 병합 딜레이 (초)
    private let coalesceDelay: TimeInterval = 0.5
    
    /// 대기 중인 이벤트 (병합용)
    private var pendingEvents: [String: FileSystemEvent] = [:]
    
    /// 병합 작업 (DispatchWorkItem 기반)
    private var coalesceWorkItem: DispatchWorkItem?
    
    /// 정책 관리자
    private let pathPolicy: PathPolicy
    
    /// 인덱서 참조
    private weak var indexer: Indexer?
    
    /// 이벤트 콜백
    var onEvent: ((FileSystemEvent) -> Void)?
    
    /// NFD 감지 콜백
    var onNFDDetected: ((String) -> Void)?
    
    /// 작업 큐
    private let workQueue = DispatchQueue(
        label: "com.hanfix.eventwatcher",
        qos: .utility
    )
    
    init(pathPolicy: PathPolicy = .shared) {
        self.pathPolicy = pathPolicy
    }
    
    /// 인덱서 설정
    func setIndexer(_ indexer: Indexer) {
        self.indexer = indexer
    }
    
    // MARK: - 감시 제어
    
    /// 감시 시작
    func start(paths: [String]? = nil) {
        guard !isWatching else { return }
        
        watchPaths = paths ?? pathPolicy.getWatchRoots()
        guard !watchPaths.isEmpty else { return }
        
        createEventStream()
        isWatching = true
    }
    
    /// 감시 중지
    func stop() {
        guard isWatching else { return }
        
        destroyEventStream()
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        pendingEvents.removeAll()
        isWatching = false
    }
    
    /// 감시 경로 변경
    func updateWatchPaths(_ paths: [String]) {
        let wasWatching = isWatching
        
        if wasWatching {
            stop()
        }
        
        watchPaths = paths
        
        if wasWatching {
            start(paths: paths)
        }
    }
    
    // MARK: - FSEvents 스트림 관리
    
    private func createEventStream() {
        let pathsToWatch = watchPaths as CFArray
        
        // 콜백 컨텍스트
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        // 스트림 플래그
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |  // 파일 레벨 이벤트
            kFSEventStreamCreateFlagNoDefer       // 즉시 전달
        )
        
        // 스트림 생성
        eventStream = FSEventStreamCreate(
            nil,                          // allocator
            eventCallback,                // callback
            &context,                     // context
            pathsToWatch,                 // pathsToWatch
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),  // sinceWhen
            0.3,                          // latency (초)
            flags                         // flags
        )
        
        guard let stream = eventStream else { return }
        
        // 스트림 스케줄링
        FSEventStreamSetDispatchQueue(stream, workQueue)
        
        // 스트림 시작
        FSEventStreamStart(stream)
    }
    
    private func destroyEventStream() {
        guard let stream = eventStream else { return }
        
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }
    
    // MARK: - 이벤트 처리
    
    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (index, path) in paths.enumerated() {
            let flag = flags[index]
            
            // 정책 확인
            guard pathPolicy.shouldWatch(path) else { continue }
            
            // 이벤트 타입 결정
            let eventType = determineEventType(flag)
            let isDirectory = (flag & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
            
            let event = FileSystemEvent(
                path: path,
                type: eventType,
                isDirectory: isDirectory,
                timestamp: Date()
            )
            
            // 이벤트 병합을 위해 대기열에 추가
            addPendingEvent(event)
        }
    }
    
    private func determineEventType(_ flag: FSEventStreamEventFlags) -> FileSystemEventType {
        if (flag & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 {
            return .created
        } else if (flag & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 {
            return .renamed
        } else if (flag & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0 {
            return .deleted
        } else if (flag & UInt32(kFSEventStreamEventFlagItemModified)) != 0 {
            return .modified
        }
        return .unknown
    }
    
    // MARK: - 이벤트 병합
    
    private func addPendingEvent(_ event: FileSystemEvent) {
        // 이벤트 병합은 workQueue에서 처리한다.

        // 같은 경로의 이벤트는 최신 것으로 덮어쓰기
        pendingEvents[event.path] = event

        // 딜레이 후 한 번에 처리
        coalesceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.processPendingEvents()
        }
        coalesceWorkItem = workItem
        workQueue.asyncAfter(deadline: .now() + coalesceDelay, execute: workItem)
    }
    
    private func processPendingEvents() {
        let events = pendingEvents
        pendingEvents.removeAll()
        
        for (_, event) in events {
            processEvent(event)
        }
    }
    
    private func processEvent(_ event: FileSystemEvent) {
        // 콜백 호출
        onEvent?(event)
        
        // 인덱서 업데이트
        switch event.type {
        case .created, .modified:
            indexer?.indexPath(event.path)
            
            // NFD 감지
            if !event.isDirectory {
                let filename = (event.path as NSString).lastPathComponent
                if UnicodeNormalizer.isNFD(filename) {
                    onNFDDetected?(event.path)
                }
            }
            
        case .deleted:
            indexer?.removePath(event.path)
            
        case .renamed:
            // FSEvents에서는 이름 변경이 두 개의 이벤트로 옴
            // 새 경로는 파일이 존재하는지로 판단
            if FileManager.default.fileExists(atPath: event.path) {
                indexer?.indexPath(event.path)
                
                // NFD 감지
                if !event.isDirectory {
                    let filename = (event.path as NSString).lastPathComponent
                    if UnicodeNormalizer.isNFD(filename) {
                        onNFDDetected?(event.path)
                    }
                }
            } else {
                indexer?.removePath(event.path)
            }
            
        case .unknown:
            break
        }
    }
}

// MARK: - FSEvents 콜백

private func eventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo = clientCallBackInfo else { return }
    
    let watcher = Unmanaged<EventWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
    
    // 경로 배열 변환
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
        return
    }
    
    // 플래그 배열 변환
    let flags = (0..<numEvents).map { eventFlags[$0] }
    
    // 이벤트 처리
    watcher.handleEvents(paths: paths, flags: flags)
}
