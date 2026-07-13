import SwiftUI
#if os(iOS)
import UIKit
#endif

struct TrainingPlanView: View {
    @State var dashboard: DashboardService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("训练计划").font(.subheadline.weight(.semibold))
                Spacer()
                if let time = dashboard.trainingUpdatedAt {
                    Text("更新于 \(fmt(time))")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Button(action: { Task { await dashboard.refreshTrainingPlan() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .disabled(dashboard.isLoadingTraining)
                if dashboard.trainingPlan != nil {
                    Button(action: {
#if os(iOS)
                        UIPasteboard.general.string = dashboard.trainingPlan
#endif
                    }) {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if dashboard.isLoadingTraining {
                if !dashboard.streamingTrainingContent.isEmpty {
                    ScrollView {
                        Text(dashboard.streamingTrainingContent)
                            .font(.body).padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Spacer()
                    ProgressView("采集数据并生成中...")
                    Spacer()
                }
            } else if let error = dashboard.trainingError {
                Spacer()
                VStack(spacing: 8) {
                    Text("❌ \(error)").font(.caption).foregroundColor(.red)
                    Button("重试") { Task { await dashboard.refreshTrainingPlan() } }
                }
                Spacer()
            } else if let plan = dashboard.trainingPlan {
                ScrollView {
                    Text(plan)
                        .font(.body).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
                Text("点击右上角刷新获取训练计划").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

struct WeeklyTrendView: View {
    @State var dashboard: DashboardService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("7日趋势").font(.subheadline.weight(.semibold))
                Spacer()
                if let time = dashboard.trendUpdatedAt {
                    Text("更新于 \(fmt(time))")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Button(action: { Task { await dashboard.refreshWeeklyTrend() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .disabled(dashboard.isLoadingTrend)
                if dashboard.weeklyTrend != nil {
                    Button(action: {
#if os(iOS)
                        UIPasteboard.general.string = dashboard.weeklyTrend
#endif
                    }) {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if dashboard.isLoadingTrend {
                if !dashboard.streamingTrendContent.isEmpty {
                    ScrollView {
                        Text(dashboard.streamingTrendContent)
                            .font(.body).padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ProgressView("采集数据并分析中...")
                    Spacer()
                }
            } else if let error = dashboard.trendError {
                Spacer()
                VStack(spacing: 8) {
                    Text("❌ \(error)").font(.caption).foregroundColor(.red)
                    Button("重试") { Task { await dashboard.refreshWeeklyTrend() } }
                }
                Spacer()
            } else if !dashboard.trendSections.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(dashboard.trendSections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(.headline)
                                    .padding(.top, 12)
                                Text(section.content)
                                    .font(.body)
                            }
                            .padding(.horizontal, 16)
                            Divider().padding(.top, 8)
                        }
                    }
                }
            } else {
                Spacer()
                Text("点击右上角刷新获取7日趋势分析").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}
