import SwiftUI
import HealthKit

struct MatchScheduleView: View {
    @State private var upcomingMatches: [MatchSchedule] = []
    @State private var pastMatches: [MatchSchedule] = []
    @State private var showingAdd = false
    @State private var showingConfirm: MatchSchedule?
    @State private var editingMatch: MatchSchedule?
    @State private var watchWorkoutDetected = false
    @State private var skipManualRecord = true
    @State private var selectedSection = 0

    private let db: DatabaseService
    private let store = HKHealthStore()

    init(db: DatabaseService) {
        self.db = db
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedSection) {
                Text("即将到来").tag(0)
                Text("已完成").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 4)

            List {
                if selectedSection == 0 {
                    if upcomingMatches.isEmpty {
                        Text("暂无即将到来的比赛").font(.caption).foregroundColor(.secondary)
                    } else {
                        ForEach(upcomingMatches) { match in
                            matchRow(match)
                                .swipeActions {
                                    Button("删除", role: .destructive) { deleteMatch(match) }
                                    Button("编辑") { editingMatch = match }
                                }
                        }
                    }
                } else {
                    if pastMatches.isEmpty {
                        Text("暂无已完成的比赛").font(.caption).foregroundColor(.secondary)
                    } else {
                        ForEach(pastMatches) { match in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(fullDate(match.date)).font(.subheadline)
                                        if let t = match.time { Text(t).font(.caption).foregroundColor(.secondary) }
                                    }
                                    if let d = match.actualDurationMin {
                                        Text("\(Int(d))分钟 \(match.actualIntensity ?? "")").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if match.isCompleted { Text("✅").font(.caption) }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.plain)

            Button(action: { showingAdd = true }) {
                Label("新增比赛", systemImage: "plus")
            }
            .padding(8)
        }
        .onAppear { loadMatches() }
        .sheet(isPresented: $showingAdd) {
            MatchFormView { match in
                try? db.insertMatchSchedule(match)
                loadMatches()
            }
        }
        .sheet(item: $editingMatch) { match in
            MatchFormView(existing: match) { updated in
                try? db.updateMatchSchedule(updated)
                loadMatches()
            }
        }
        .sheet(item: $showingConfirm) { match in
            confirmView(match)
        }
    }

    private func matchRow(_ match: MatchSchedule) -> some View {
        let isOverdue = match.date < Calendar.current.startOfDay(for: Date())
        return Button {
            showingConfirm = match
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(fullDate(match.date)).font(.subheadline)
                        if let t = match.time { Text(t).font(.caption).foregroundColor(.secondary) }
                        if isOverdue {
                            Text("待确认").font(.caption2).foregroundColor(.red)
                                .padding(.horizontal, 4).background(Color.red.opacity(0.1)).cornerRadius(4)
                        }
                    }
                    HStack(spacing: 8) {
                        if let intensity = match.intensity {
                            Text(intensityLabel(intensity)).font(.caption).foregroundColor(.secondary)
                        }
                        if let opp = match.opponent { Text(opp).font(.caption).foregroundColor(.secondary) }
                    }
                }
                Spacer()
                Image(systemName: "checkmark.circle").foregroundColor(.blue)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func confirmView(_ match: MatchSchedule) -> some View {
        NavigationStack {
            Form {
                Section("比赛信息") {
                    LabeledContent("日期") { Text(fullDate(match.date)) }
                    if let t = match.time { LabeledContent("时间") { Text(t) } }
                    if let i = match.intensity { LabeledContent("强度") { Text(intensityLabel(i)) } }
                }

                Section("确认完成") {
                    TextField("实际分钟数", value: .constant(match.actualDurationMin ?? 90), format: .number)
                    Picker("实际强度", selection: .constant(match.actualIntensity ?? match.intensity ?? "medium")) {
                        Text("高强度").tag("high")
                        Text("中等").tag("medium")
                        Text("低强度").tag("low")
                    }
                    if watchWorkoutDetected {
                        Toggle("Watch 已检测到同期训练记录，跳过人工记录", isOn: $skipManualRecord)
                            .font(.caption)
                    }
                }

                Section {
                    Button("确认提交") {
                        var updated = match
                        updated.isCompleted = true
                        updated.actualIntensity = updated.actualIntensity ?? updated.intensity
                        try? db.updateMatchSchedule(updated)

                        if !watchWorkoutDetected || !skipManualRecord {
                            let activity = ActivityLog(
                                id: UUID(), date: match.date, type: "Match",
                                durationMin: updated.actualDurationMin, distanceKm: nil,
                                intensity: updated.actualIntensity, notes: "比赛: \(match.opponent ?? "")",
                                createdAt: Date()
                            )
                            try? db.insertActivityLog(activity)
                        }
                        showingConfirm = nil
                        loadMatches()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("确认比赛")
            .task {
                watchWorkoutDetected = await checkWatchWorkout(match)
                skipManualRecord = watchWorkoutDetected
            }
        }
    }

    private func checkWatchWorkout(_ match: MatchSchedule) async -> Bool {
        let cal = Calendar.current
        guard let start = cal.date(bySettingHour: 0, minute: 0, second: 0, of: match.date),
              let end = cal.date(byAdding: .day, value: 1, to: start) else { return false }

        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKWorkout] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKWorkoutType.workoutType(), predicate: pred, limit: 10, sortDescriptors: [sort]) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
        return !samples.isEmpty
    }

    private func loadMatches() {
        upcomingMatches = (try? db.queryUpcomingMatches(limit: 20)) ?? []
        pastMatches = (try? db.queryPastMatches(limit: 20)) ?? []
    }

    private func deleteMatch(_ match: MatchSchedule) {
        try? db.deleteMatchSchedule(id: match.id)
        loadMatches()
    }

    private func fullDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M月d日 EEEE"
        return f.string(from: d)
    }

    private func intensityLabel(_ i: String) -> String {
        switch i {
        case "high": return "高强度"
        case "medium": return "中等"
        case "low": return "低强度"
        default: return i
        }
    }
}

// MARK: - Add/Edit Form

struct MatchFormView: View {
    let existing: MatchSchedule?
    let onSave: (MatchSchedule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var time = "20:00"
    @State private var intensity = "medium"
    @State private var opponent = ""
    @State private var notes = ""

    init(existing: MatchSchedule? = nil, onSave: @escaping (MatchSchedule) -> Void) {
        self.existing = existing
        self.onSave = onSave
        if let m = existing {
            _date = State(initialValue: m.date)
            _time = State(initialValue: m.time ?? "20:00")
            _intensity = State(initialValue: m.intensity ?? "medium")
            _opponent = State(initialValue: m.opponent ?? "")
            _notes = State(initialValue: m.notes ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("时间 (HH:MM)", text: $time)
                    Picker("强度", selection: $intensity) {
                        Text("高强度").tag("high")
                        Text("中等").tag("medium")
                        Text("低强度").tag("low")
                    }
                }
                Section("可选") {
                    TextField("对手", text: $opponent)
                    TextField("备注", text: $notes)
                }
            }
            .navigationTitle(existing == nil ? "新增比赛" : "编辑比赛")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let match = MatchSchedule(
                            id: existing?.id ?? UUID(),
                            date: date, time: time, opponent: opponent.isEmpty ? nil : opponent,
                            intensity: intensity, notes: notes.isEmpty ? nil : notes,
                            actualDurationMin: existing?.actualDurationMin,
                            actualIntensity: existing?.actualIntensity,
                            isCompleted: existing?.isCompleted ?? false,
                            createdAt: existing?.createdAt ?? Date()
                        )
                        onSave(match)
                        dismiss()
                    }
                }
            }
        }
    }
}
