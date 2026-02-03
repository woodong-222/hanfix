//
//  HanFixApp.swift
//  HanFix

import SwiftUI

@main
struct HanFixApp: App {
    var body: some Scene {
        MenuBarExtra("HanFix", systemImage: "keyboard") {
            Button("한글 변환 실행") {
                print("미구현")
            }
            
            Divider() // 구분선
            
            Button("종료") {
                print("앱 종료")
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
