import SwiftUI
import Charts
import UIKit

struct SportsView: View {
    private enum Tab: String, CaseIterable { case overview = "概览", trends = "趋势图表", records = "运动记录" }
    @StateObject private var store = SportsStore()
    @State private var tab = Tab.overview
    @State private var year = Calendar(identifier: .gregorian).component(.year, from: .now)
    @State private var month = Calendar(identifier: .gregorian).component(.month, from: .now)
    @State private var adding = false
    @State private var entered = false

    private var years: [Int] {
        Set(store.records.compactMap { Int($0.year) } + [year, Calendar(identifier: .gregorian).component(.year, from: .now)]).sorted(by: >)
    }
    private var records: [SportsRecord] { store.records.filter { $0.year == String(year) } }
    private var filtered: [SportsRecord] { records.filter { month == 0 || $0.month == month } }

    var body: some View {
        List {
            if store.syncing {
                Section { ProgressView("正在从 GitHub 拉取、合并并同步…") }
            }
            if let message = store.message {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.red)
                        .accessibilityLabel(message)
                }
            }
            Section {
                HakoUnderlineTabs(title: "运动模块", options: Tab.allCases, selection: $tab, label: { $0.rawValue })
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                Picker("年份", selection: $year) {
                    ForEach(years, id: \.self) { Text(String($0) + " 年").tag($0) }
                }
            }
            switch tab {
            case .overview: overview
            case .trends:
                ForEach(SportsMetric.allCases) { metric in
                    chart(metric)
                    chart(metric, cumulative: true)
                }
            case .records:
                Section {
                    Picker("月份", selection: $month) {
                        Text("全年").tag(0)
                        ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
                    }
                    Text("\(filtered.count) 次运动 · \(filtered.reduce(0) { $0 + $1.distance }, specifier: "%.2f") km · \(filtered.reduce(0.0) { $0 + Double($1.duration) } / 60, specifier: "%.1f") 小时")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                recordList(filtered, title: "运动记录")
            }
            Section {
                if store.pendingCount > 0 {
                    Text("\(store.pendingCount) 项变更待同步，下次进入时自动处理。")
                } else if let time = store.state.syncedAt {
                    Text("已自动同步：\(time.formatted(date: .abbreviated, time: .shortened))")
                }
            } footer: { Text("沿用主应用 GitHub 配置，每次进入自动同步。\ndata/sports/\(String(year)).csv") }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("运动记录")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("记录运动").disabled(store.syncing)
            }
        }
        .sheet(isPresented: $adding) { SportsEditor(store: store) }
        .task {
            guard !entered else { return }
            entered = true
            await store.synchronize()
        }
    }

    @ViewBuilder private var overview: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                metric("运动次数", String(records.count), "次")
                metric("运动距离", String(format: "%.2f", records.reduce(0) { $0 + $1.distance }), "km")
                metric("运动时长", String(format: "%.1f", records.reduce(0.0) { $0 + Double($1.duration) } / 60), "小时")
                metric("运动天数", String(Set(records.map(\.date)).count), "天")
            }.padding(.vertical, 10)
        }
        chart(.count)
        chart(.duration)
        recordList(Array(records.prefix(3)), title: "最近运动")
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            (Text(value).font(.title2.weight(.semibold)) + Text(" " + unit).font(.caption))
                .monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chart(_ metric: SportsMetric, cumulative: Bool = false) -> some View {
        Section((cumulative ? "累计" : "每月") + metric.title) {
            SportsChart(records: records, metric: metric, cumulative: cumulative, year: year)
        }
    }

    private func recordList(_ values: [SportsRecord], title: String) -> some View {
        Section(title) {
            if values.isEmpty {
                ContentUnavailableView("还没有运动记录", systemImage: "figure.run", description: Text("点击右上角加号记录运动。"))
            }
            ForEach(values) { record in
                NavigationLink { SportsDetail(store: store, id: record.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: SportsChart.symbol(record.type))
                            .foregroundStyle(SportsChart.color(record.type)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.type).font(.headline)
                            Text(record.date + (store.isPending(record.id) ? " · 待同步" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("\(record.distance, specifier: "%.2f") km").monospacedDigit()
                            Text("\(record.duration) 分钟").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }.disabled(store.syncing)
            }
        }
    }
}

private struct SportsChart: View {
    let records: [SportsRecord]
    let metric: SportsMetric
    let cumulative: Bool
    let year: Int
    @State private var selectedMonth: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static func symbol(_ type: String) -> String {
        switch type { case "Swimming": "figure.pool.swim"; case "Biking": "figure.outdoor.cycle"; case "Hiking": "figure.hiking"; default: "figure.walk" }
    }
    static func color(_ type: String) -> Color {
        switch type { case "Swimming": .teal; case "Biking": .blue; case "Hiking": .purple; case "Walking": .orange; default: .gray }
    }
    private var types: [String] { Set(records.map(\.type)).sorted() }
    private var months: Int {
        let calendar = Calendar(identifier: .gregorian)
        return year == calendar.component(.year, from: .now) ? calendar.component(.month, from: .now) : 12
    }

    var body: some View {
        if records.isEmpty {
            Text("本年度暂无数据").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            let points = SportsStatistics.points(records, metric: metric, cumulative: cumulative, months: months)
            VStack(alignment: .leading, spacing: 10) {
                Text(metric.unit).font(.caption).foregroundStyle(.secondary)
                Chart(points) { point in
                    if cumulative {
                        LineMark(x: .value("月份", point.month), y: .value(metric.unit, point.value))
                            .foregroundStyle(by: .value("运动类型", point.type))
                            .symbol(by: .value("运动类型", point.type))
                    } else {
                        BarMark(x: .value("月份", point.month), y: .value(metric.unit, point.value))
                            .foregroundStyle(by: .value("运动类型", point.type))
                    }
                }
                .chartForegroundStyleScale(domain: types, range: types.map { Self.color($0) })
                .chartXScale(domain: 0.5...12.5)
                .chartXAxis {
                    AxisMarks(values: [1, 4, 7, 10, 12]) { value in
                        AxisGridLine()
                        AxisValueLabel { if let month = value.as(Int.self) { Text("\(month)月") } }
                    }
                }
                .chartXSelection(value: $selectedMonth)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 260 : 190)
                .accessibilityLabel("\(year) 年\(cumulative ? "累计" : "每月")\(metric.title)，单位\(metric.unit)")
                if let month = selectedMonth, (1...months).contains(month) {
                    Text("\(month) 月：" + points.filter { $0.month == month }.map {
                        "\($0.type) \(String(format: metric == .count ? "%.0f" : "%.2f", $0.value)) \(metric.unit)"
                    }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 8)
        }
    }
}

private struct SportsDetail: View {
    @ObservedObject var store: SportsStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var deleting = false
    @State private var error: String?

    private var record: SportsRecord? { store.state.records.first { $0.id == id } }

    var body: some View {
        List {
            if let record {
                Section {
                    Label(record.type, systemImage: SportsChart.symbol(record.type)).font(.title2)
                        .foregroundStyle(SportsChart.color(record.type))
                    LabeledContent("日期", value: record.date)
                    LabeledContent("运动距离", value: String(format: "%.2f km", record.distance))
                    LabeledContent("运动时长", value: "\(record.duration) 分钟")
                    LabeledContent("同步状态", value: store.isPending(id) ? "待同步" : "已同步")
                }
                Section {
                    Button("删除运动记录", role: .destructive) { deleting = true }.disabled(store.syncing)
                } footer: { Text("修改和删除先保存在本地，下次进入运动子应用时自动同步。") }
            } else { ContentUnavailableView("记录已不存在", systemImage: "figure.run") }
        }
        .navigationTitle("运动详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { editing = true }.disabled(record == nil || store.syncing)
            }
        }
        .sheet(isPresented: $editing) { if let record { SportsEditor(store: store, record: record) } }
        .confirmationDialog("删除这条运动记录？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除运动记录", role: .destructive) {
                do { try store.delete(id); dismiss() } catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("删除后从列表和图表移除，下次进入时同步删除操作。") }
        .alert("无法删除记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct SportsEditor: View {
    @ObservedObject var store: SportsStore
    let record: SportsRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var type: String
    @State private var distance: String
    @State private var duration: String
    @State private var error: String?

    private static var today: Date {
        let local = SportsRecord.formatter()
        local.timeZone = .current
        return SportsRecord.formatter().date(from: local.string(from: .now))!
    }
    init(store: SportsStore, record: SportsRecord? = nil) {
        self.store = store; self.record = record
        _date = State(initialValue: record.flatMap { SportsRecord.formatter().date(from: $0.date) } ?? Self.today)
        _type = State(initialValue: record?.type ?? "Swimming")
        _distance = State(initialValue: record.map { String($0.distance) } ?? "")
        _duration = State(initialValue: record.map { String($0.duration) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("日期", selection: $date, in: ...Self.today.addingTimeInterval(86_399), displayedComponents: .date)
                    Picker("运动类型", selection: $type) {
                        ForEach(Set(SportsRecord.types + [type]).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    field("运动距离 · km", value: $distance, placeholder: "例如 1.05", keyboard: .decimalPad)
                    field("运动时长 · 分钟", value: $duration, placeholder: "例如 69", keyboard: .numberPad)
                } footer: { Text("无距离的运动填 0；同一天可以记录多次运动。保存后，下次进入时自动同步。") }
            }
            // Date-only records must not move to a neighboring day in a different local zone.
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .navigationTitle(record == nil ? "记录运动" : "编辑运动记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(store.syncing) }
            }
            .alert("无法保存记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func field(_ name: String, value: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            TextField(placeholder, text: value).keyboardType(keyboard).accessibilityLabel(name)
        }
    }

    private func save() {
        guard let distance = Double(distance.replacingOccurrences(of: ",", with: ".")), let duration = Int(duration) else {
            error = "请输入有效距离和正整数分钟时长。"; return
        }
        do {
            try store.save(SportsRecord(id: record?.id ?? UUID(), date: SportsRecord.formatter().string(from: date),
                                        type: type, distance: distance, duration: duration))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
