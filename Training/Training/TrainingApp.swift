//
//  TrainingApp.swift
//  Training
//

import SwiftUI

@main
struct TrainingApp: App {
    init() {
        clearDashboardCacheIfNeeded()
        AppVersion.writeMarker()
    }

    var body: some Scene {
        WindowGroup {
            if let idx = scenarioIndex() {
                SelfTestSingleView(scenarioIndex: idx)
            } else if AppConfig.isSelfTestMode || CommandLine.arguments.contains("--self-test") {
                SelfTestHostView()
            } else {
                ContentView()
            }
        }
    }

    /// 自测时安全清趋势/训练缓存（只清 UserDefaults 两个 key，绝不卸载 App、绝不碰 training.db）。
    /// 规矩：不论如何不能丢数据库数据。卸载会清整个沙盒含 DB，禁止用卸载清缓存。
    private func clearDashboardCacheIfNeeded() {
        guard CommandLine.arguments.contains("--clear-dashboard-cache") else { return }
        let d = UserDefaults.standard
        d.removeObject(forKey: "dashboard_weekly_trend")
        d.removeObject(forKey: "dashboard_trend_time")
        d.removeObject(forKey: "dashboard_training_plan")
        d.removeObject(forKey: "dashboard_training_time")
    }

    private func scenarioIndex() -> Int? {
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--self-test-scenario="),
               let idx = Int(arg.dropFirst("--self-test-scenario=".count)) {
                return idx
            }
        }
        return nil
    }
}
