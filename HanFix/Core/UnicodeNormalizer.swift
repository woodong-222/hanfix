//
//  UnicodeNormalizer.swift
//  HanFix
//
//  Unicode NFD/NFC 정규화 유틸리티
//

import Foundation

/// Unicode 정규화 유틸리티
enum UnicodeNormalizer {
    
    // MARK: - NFD 감지
    
    /// 문자열이 NFD(자소 분리) 형태인지 확인
    /// - Parameter string: 검사할 문자열
    /// - Returns: NFD 형태이면 true
    static func isNFD(_ string: String) -> Bool {
        // Swift String equality uses canonical equivalence; compare scalars to detect NFD.
        let nfc = string.precomposedStringWithCanonicalMapping
        return !string.unicodeScalars.elementsEqual(nfc.unicodeScalars)
    }
    
    /// 파일명에 NFD가 포함되어 있는지 확인
    /// - Parameter url: 파일 URL
    /// - Returns: NFD 파일명이면 true
    static func hasNFDFilename(at url: URL) -> Bool {
        let filename = url.lastPathComponent
        return isNFD(filename)
    }
    
    /// 경로 문자열에서 파일명이 NFD인지 확인
    /// - Parameter path: 파일 경로
    /// - Returns: NFD 파일명이면 true
    static func hasNFDFilename(atPath path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent
        return isNFD(filename)
    }
    
    // MARK: - NFC 변환
    
    /// 문자열을 NFC(완성형)로 변환
    /// - Parameter string: 변환할 문자열
    /// - Returns: NFC로 정규화된 문자열
    static func toNFC(_ string: String) -> String {
        return string.precomposedStringWithCanonicalMapping
    }
    
    /// 파일명만 NFC로 변환한 URL 반환
    /// - Parameter url: 원본 URL
    /// - Returns: 파일명이 NFC로 변환된 URL
    static func urlWithNFCFilename(from url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        let nfcFilename = toNFC(filename)
        return directory.appendingPathComponent(nfcFilename)
    }
    
    /// 경로의 파일명만 NFC로 변환
    /// - Parameter path: 원본 경로
    /// - Returns: 파일명이 NFC로 변환된 경로
    static func pathWithNFCFilename(from path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        let nfcFilename = toNFC(filename)
        return (directory as NSString).appendingPathComponent(nfcFilename)
    }
}

// MARK: - String Extension

extension String {
    /// NFD 문자열인지 확인
    var isNFD: Bool {
        UnicodeNormalizer.isNFD(self)
    }
    
    /// NFC로 변환된 문자열
    var nfc: String {
        UnicodeNormalizer.toNFC(self)
    }
}
