import SwiftUI
import SwiftData
import FamilyControls
import ManagedSettings

struct UsageEntry: View {
    var body: some View {
        switch UsageDatabase.shared {
        case .success(let container): UsageView().modelContainer(container)
        case .failure(let error):
            ContentUnavailableView("使用时间数据库无法打开", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text(error.localizedDescription))
                .navigationTitle("使用时间")
        }
    }
}

struct UsageView: View {
    private enum Tab: String, CaseIterable { case overview = "概览", trends = "趋势图表", records = "使用记录" }
    @ObservedObject private var authorization = AuthorizationCenter.shared
    @State private var installedApplications: [String: Application] = [:]
    @Query(sort: \DailyUsage.day, order: .reverse) private var records: [DailyUsage]
    @State private var tab = Tab.overview
    @State private var year = Calendar(identifier: .gregorian).component(.year, from: .now)
    @State private var busy = false
    @State private var collecting = false
    @State private var collectionQueued = false
    @State private var mergedSuccessfully = false
    @State private var entered = false
    @State private var message: String?
    @State private var syncedAt: Date?
    @State private var selectedDay: String?
    @State private var showDatePicker = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var years: [Int] { Set(records.compactMap { Int($0.day.prefix(4)) } + [year]).sorted(by: >) }
    private var scoped: [DailyUsage] { records.filter { Int($0.day.prefix(4)) == year } }
    private var values: [UsageDayValue] { scoped.map { UsageDayValue(day: $0.day, seconds: $0.totalSeconds) } }
    private var activeDay: String? {
        if let selectedDay, records.contains(where: { $0.day == selectedDay }) { return selectedDay }
        return records.first?.day
    }
    private var selectedRecord: DailyUsage? { records.first { $0.day == activeDay } }
    private var syncStatus: String {
        if collectionQueued { return "正在合并 · 随后采集同步" }
        if busy { return collecting ? "正在采集并同步…" : "正在自动合并…" }
        if message != nil { return "自动同步失败" }
        if let syncedAt { return "已自动同步 " + syncedAt.formatted(date: .omitted, time: .shortened) }
        return "GitHub · 进入时自动合并"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                tabs
                scopeControl
                if let message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
                switch tab {
                case .overview:
                    summary
                    UsageChart(values: values, year: year, metric: .total)
                    if let latest = scoped.first { dayDetails(latest, latest: true) }
                    else { emptyState }
                case .trends:
                    summary
                    UsageDailyChart(values: records.map { UsageDayValue(day: $0.day, seconds: $0.totalSeconds) }, year: year, movingAverages: false)
                    UsageDailyChart(values: records.map { UsageDayValue(day: $0.day, seconds: $0.totalSeconds) }, year: year, movingAverages: true)
                    Text("按月份统计总使用时长、日均时长与累计时长；日均值按有记录的天数计算。")
                        .font(.caption).foregroundStyle(UsageStyle.muted).lineSpacing(4)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                        ForEach(UsageChartMetric.allCases, id: \.self) { metric in
                            UsageChart(values: values, year: year, metric: metric)
                        }
                    }
                case .records:
                    if let selectedRecord { dayDetails(selectedRecord, latest: false) }
                    else { emptyState }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .background(UsageStyle.background).foregroundStyle(UsageStyle.text)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(UsageStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showDatePicker) {
            UsageCalendarSheet(available: Set(records.map(\.day)), selected: activeDay) { selectedDay = $0 }
        }
        .task {
            guard !entered else { return }
            entered = true
            execute(collect: false)
        }
        .task(id: authorization.authorizationStatus) {
            installedApplications = await ScreenTime.installedApplications()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("使用时间").font(.system(size: 28, weight: .bold)).tracking(-0.7)
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    else { Circle().fill(message == nil ? UsageStyle.series : .red).frame(width: 5, height: 5) }
                    Text(syncStatus).font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
                }.accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            Button { execute(collect: true) } label: {
                Label("采集并同步", systemImage: "arrow.down.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .foregroundStyle(UsageStyle.card)
                    .background(UsageStyle.text, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("获取 app 使用时间并同步")
            .accessibilityHint("采集最近七个完整自然日，不含今天，并同步到 GitHub。")
        }
    }

    private var tabs: some View {
        HStack(spacing: 25) {
            ForEach(Tab.allCases, id: \.self) { option in
                Button { tab = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 14, weight: tab == option ? .semibold : .regular))
                        .foregroundStyle(tab == option ? UsageStyle.text : UsageStyle.muted)
                        .padding(.horizontal, 1).frame(minHeight: 44)
                        .overlay(alignment: .bottom) { Rectangle().fill(tab == option ? UsageStyle.text : .clear).frame(height: 2) }
                }
                .buttonStyle(.plain).accessibilityAddTraits(tab == option ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Rectangle().fill(UsageStyle.line).frame(height: 1) }
        .accessibilityLabel("使用时间页签")
    }

    private var scopeControl: some View {
        HStack(spacing: 12) {
            if tab == .records {
                Button { showDatePicker = true } label: {
                    filterLabel(activeDay.map(UsageDates.title) ?? "选择日期", symbol: "calendar")
                }.buttonStyle(.plain).disabled(records.isEmpty)
                    .accessibilityLabel("选择年、月、日，仅有记录的日期可选")
            } else {
                Menu {
                    Picker("统计年份", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0) + " 年").tag($0) }
                    }
                } label: { filterLabel(String(year) + " 年", symbol: nil) }
            }
            Spacer(minLength: 0)
            Text(tab == .overview ? "年度概览" : tab == .trends ? "年度趋势" : "按日回顾")
                .font(.caption).foregroundStyle(UsageStyle.muted)
        }
    }
    private func filterLabel(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .font(.system(size: 13)).padding(.horizontal, 11).frame(minHeight: 44)
        .background(UsageStyle.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(UsageStyle.line, lineWidth: 1) }
    }

    @ViewBuilder private var summary: some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) { metrics }.usagePanel()
        } else {
            HStack(spacing: 0) { metrics }.padding(.vertical, 17).padding(.horizontal, 4)
                .background(UsageStyle.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }
    @ViewBuilder private var metrics: some View {
        let total = scoped.reduce(0) { $0 + $1.totalSeconds } / 3600
        UsageMetricValue(title: "总使用时长", value: String(format: "%.1f", total), unit: "小时")
        if !dynamicTypeSize.isAccessibilitySize { Rectangle().fill(UsageStyle.line).frame(width: 1, height: 38).accessibilityHidden(true) }
        UsageMetricValue(title: "日均时长", value: String(format: "%.1f", total / Double(max(1, scoped.count))), unit: "小时")
        if !dynamicTypeSize.isAccessibilitySize { Rectangle().fill(UsageStyle.line).frame(width: 1, height: 38).accessibilityHidden(true) }
        UsageMetricValue(title: "记录天数", value: String(scoped.count), unit: "天")
    }

    private func dayDetails(_ record: DailyUsage, latest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(latest ? "最近一天" : "使用详情").font(.system(size: 16, weight: .semibold))
                Spacer()
                if latest {
                    Button {
                        selectedDay = record.day
                        tab = .records
                    } label: {
                        HStack(spacing: 5) { Text("全部记录"); Image(systemName: "chevron.right").font(.system(size: 10)) }
                            .font(.caption).foregroundStyle(.blue).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(UsageDates.title(record.day) + " · " + (record.syncedAt == nil ? "待同步" : "已同步"))
                    .font(.system(size: 12)).foregroundStyle(UsageStyle.muted)
                Text(UsageDates.duration(record.totalSeconds)).font(.title.bold()).monospacedDigit()
                Text("总使用时长").font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
            }
            Text("使用时长 Top 5").font(.system(size: 16, weight: .semibold)).padding(.top, 3)
            appRows(record)
            Text("时区：" + record.timeZone).font(.system(size: 11)).foregroundStyle(UsageStyle.muted)
        }
        .usagePanel(padding: 18)
    }

    private func appRows(_ record: DailyUsage) -> some View {
        let apps = Array(record.apps.sorted { $0.seconds > $1.seconds }.prefix(5))
        return VStack(spacing: 0) {
            if apps.isEmpty {
                Text("暂无应用明细").font(.caption).foregroundStyle(UsageStyle.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(apps.enumerated()), id: \.element.bundleID) { index, app in
                if index > 0 { Rectangle().fill(UsageStyle.line).frame(height: 1) }
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            appName(app, rank: index + 1)
                            Spacer(minLength: 4)
                            appDuration(app)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            appName(app, rank: index + 1)
                            appDuration(app)
                        }
                    }
                    GeometryReader { geometry in
                        Capsule().fill(UsageStyle.background)
                            .overlay(alignment: .leading) {
                                Capsule().fill(UsageStyle.series)
                                    .frame(width: geometry.size.width * max(0, min(1, app.seconds / max(1, apps.first?.seconds ?? 1))))
                            }
                    }.frame(height: 5).accessibilityHidden(true)
                }.padding(.vertical, 13)
            }
        }
    }
    private func appName(_ app: AppUsage, rank: Int) -> some View {
        HStack(spacing: 10) {
            Text(String(rank)).monospacedDigit().foregroundStyle(UsageStyle.muted)
            UsageAppTitle(app: app, installed: installedApplications[app.bundleID]).lineLimit(2)
        }.font(.system(size: 13))
    }
    private func appDuration(_ app: AppUsage) -> some View {
        Text(UsageDates.duration(app.seconds)).font(.system(size: 13)).monospacedDigit().fixedSize()
    }
    private var emptyState: some View {
        ContentUnavailableView("还没有记录", systemImage: "clock",
                               description: Text("进入页面时自动合并 GitHub 历史记录；点击右上角「采集并同步」获取最近七天的数据。"))
            .usagePanel()
    }
    private func execute(collect: Bool) {
        if busy {
            // One tap during entry merge schedules collection; repeated taps coalesce.
            if collect && !collecting { collectionQueued = true }
            return
        }
        busy = true; collecting = collect; message = nil
        Task {
            defer {
                busy = false
                if collectionQueued {
                    collectionQueued = false
                    execute(collect: true)
                }
            }
            do {
                if collect && !mergedSuccessfully {
                    _ = try await Recorder.shared.run(collect: false)
                    mergedSuccessfully = true
                }
                _ = try await Recorder.shared.run(collect: collect, requestAuthorization: collect)
                if !collect { mergedSuccessfully = true }
                syncedAt = .now
            } catch { message = "同步失败：\(error.localizedDescription)\n本地记录已保留，下次进入时自动重试。" }
        }
    }
}

private struct UsageAppTitle: View {
    let app: AppUsage
    let installed: Application?
    @ScaledMetric(relativeTo: .body) private var iconSize = 28.0
    var body: some View {
        let name = [installed?.localizedDisplayName, app.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != app.bundleID }
        let token = installed?.token ?? app.applicationTokenData.flatMap {
            try? JSONDecoder().decode(ApplicationToken.self, from: $0)
        }
        HStack(spacing: 8) {
            Group {
                if let token {
                    Label(token).labelStyle(.iconOnly)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: iconSize * 0.65))
                        .foregroundStyle(UsageStyle.muted)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .background(UsageStyle.background, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            if let name { Text(name) }
            else if let token { Label(token).labelStyle(.titleOnly) }
            else { Text(app.bundleID) }
        }
    }
}
