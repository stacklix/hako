import SwiftUI
import UIKit

struct SportsView: View {
    private enum Tab: String, CaseIterable { case overview = "概览", trends = "趋势图表", records = "运动记录" }
    @StateObject private var store = SportsStore()
    @State private var tab = Tab.overview
    @State private var year = Calendar(identifier: .gregorian).component(.year, from: .now)
    @State private var month = 0
    @State private var overall = false
    @State private var adding = false
    @State private var entered = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var years: [Int] {
        Set(store.records.compactMap { Int($0.year) } + [year, Calendar(identifier: .gregorian).component(.year, from: .now)]).sorted(by: >)
    }
    private var isOverall: Bool { overall && tab != .records }
    private var scopeYear: Int? { isOverall ? nil : year }
    private var scopeLabel: String { isOverall ? "总体" : String(year) + " 年" }
    private var yearSelection: Binding<Int> {
        Binding(get: { isOverall ? 0 : year }, set: { value in
            if value == 0 { overall = true }
            else { year = value; overall = false }
        })
    }
    private var records: [SportsRecord] { store.records.filter { isOverall || $0.year == String(year) } }
    private var filtered: [SportsRecord] { records.filter { month == 0 || $0.month == month } }
    private var period: String {
        switch tab { case .overview: isOverall ? "全部年份概览" : "年度概览"; case .trends: isOverall ? "跨年汇总与累计" : "六项年度趋势"; case .records: "按月回顾" }
    }
    private var syncStatus: String {
        if store.syncing { return "正在自动同步…" }
        if store.message != nil { return "自动同步失败" }
        if store.pendingCount > 0 { return "\(store.pendingCount) 项待同步 · 下次进入自动处理" }
        if let time = store.state.syncedAt { return "已自动同步 " + time.formatted(date: .omitted, time: .shortened) }
        return "GitHub · 进入时自动拉取"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                tabs
                HStack {
                    Menu {
                        Picker("统计范围", selection: yearSelection) {
                            if tab != .records { Text("总体 · 全部年份").tag(0) }
                            ForEach(years, id: \.self) { Text(String($0) + " 年").tag($0) }
                        }
                    } label: { filterLabel(scopeLabel) }
                    .accessibilityLabel("统计范围，" + scopeLabel)
                    Spacer()
                    Text(period).font(.caption).foregroundStyle(SportsStyle.muted)
                }
                if let message = store.message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(message)
                }
                switch tab {
                case .overview: overview
                case .trends:
                    summaryMetrics
                    Text(isOverall ? "按年份汇总运动次数、时长与距离；累计值从最早记录年份起计算。" : "按运动类型统计每月次数、时长与距离；累计值从所选年份的 1 月起计算。")
                        .font(.caption).foregroundStyle(SportsStyle.muted).lineSpacing(4)
                    // Wide layouts match the prototype's two columns; phones keep one readable chart per row.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                        ForEach(SportsMetric.allCases) { metric in
                            SportsChart(records: records, metric: metric, cumulative: false, year: scopeYear)
                            SportsChart(records: records, metric: metric, cumulative: true, year: scopeYear)
                        }
                    }
                case .records:
                    HStack {
                        Text("运动记录").font(.subheadline.weight(.semibold))
                        Spacer()
                        Menu {
                            Picker("月份", selection: $month) {
                                Text("全年").tag(0)
                                ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
                            }
                        } label: { filterLabel(month == 0 ? "全年" : "\(month) 月") }
                        .accessibilityLabel("按月份筛选，" + (month == 0 ? "全年" : "\(month) 月"))
                    }
                    Text("\(month == 0 ? "全年" : "\(month) 月") · \(filtered.count) 次运动 · \(filtered.reduce(0) { $0 + $1.distance }, specifier: "%.1f") km · \(filtered.reduce(0.0) { $0 + Double($1.duration) } / 60, specifier: "%.1f") 小时")
                        .font(.caption).foregroundStyle(SportsStyle.muted)
                    recordList(filtered)
                        .sportsPanel()
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .background(SportsStyle.background)
        .foregroundStyle(SportsStyle.text)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(SportsStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $adding) { SportsEditor(store: store) }
        .task {
            guard !entered else { return }
            entered = true
            await store.synchronize()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("运动记录").font(.system(size: 28, weight: .bold)).tracking(-0.7)
                HStack(spacing: 6) {
                    if store.syncing { ProgressView().controlSize(.mini) }
                    else { Circle().fill(store.message == nil ? SportsStyle.color("Swimming") : .red).frame(width: 5, height: 5) }
                    Text(syncStatus).font(.system(size: 11)).foregroundStyle(SportsStyle.muted)
                }.accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            Button { adding = true } label: {
                Label("记录运动", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .foregroundStyle(SportsStyle.card)
                    .background(SportsStyle.text, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).disabled(store.syncing)
        }
    }

    private var tabs: some View {
        HStack(spacing: 25) {
            ForEach(Tab.allCases, id: \.self) { option in
                Button { tab = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 14, weight: tab == option ? .semibold : .regular))
                        .foregroundStyle(tab == option ? SportsStyle.text : SportsStyle.muted)
                        .padding(.horizontal, 1).frame(minHeight: 44)
                        .overlay(alignment: .bottom) { Rectangle().fill(tab == option ? SportsStyle.text : .clear).frame(height: 2) }
                }
                .buttonStyle(.plain).accessibilityAddTraits(tab == option ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Rectangle().fill(SportsStyle.line).frame(height: 1) }
        .padding(.top, 3)
        .accessibilityElement(children: .contain).accessibilityLabel("运动模块")
    }

    private func filterLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .font(.system(size: 13)).padding(.horizontal, 11).frame(minHeight: 44)
        .background(SportsStyle.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(SportsStyle.line, lineWidth: 1) }
    }

    @ViewBuilder private var overview: some View {
        summaryMetrics
        SportsChart(records: records, metric: .count, cumulative: false, year: scopeYear)
        SportsChart(records: records, metric: .duration, cumulative: false, year: scopeYear)
        VStack(spacing: 6) {
            HStack {
                Text("最近运动").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { tab = .records } label: {
                    HStack(spacing: 5) { Text("全部记录"); Image(systemName: "chevron.right").font(.system(size: 10)) }
                        .font(.caption).foregroundStyle(SportsStyle.muted).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
            recordList(Array(records.prefix(3)))
        }.sportsPanel()
    }

    @ViewBuilder private var summaryMetrics: some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) { metrics }
                .sportsPanel()
        } else {
            HStack(spacing: 0) { metrics }.padding(.vertical, 17).padding(.horizontal, 4)
                .background(SportsStyle.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder private var metrics: some View {
        SportsMetricValue(title: "运动次数", value: String(records.count), unit: "次")
        metricDivider
        SportsMetricValue(title: "运动距离", value: String(format: "%.1f", records.reduce(0) { $0 + $1.distance }), unit: "km")
        metricDivider
        SportsMetricValue(title: "运动时长", value: String(format: "%.1f", records.reduce(0.0) { $0 + Double($1.duration) } / 60), unit: "小时")
        metricDivider
        SportsMetricValue(title: "运动天数", value: String(Set(records.map(\.date)).count), unit: "天")
    }
    @ViewBuilder private var metricDivider: some View {
        if !dynamicTypeSize.isAccessibilitySize { Rectangle().fill(SportsStyle.line).frame(width: 1, height: 40).accessibilityHidden(true) }
    }

    @ViewBuilder private func recordList(_ values: [SportsRecord]) -> some View {
        if values.isEmpty {
            Text("还没有运动记录\n点击「记录运动」添加第一条。")
                .font(.system(size: 13)).foregroundStyle(SportsStyle.muted)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 28)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Rectangle().fill(SportsStyle.line).frame(height: 1) }
                    NavigationLink { SportsDetail(store: store, id: record.id) } label: {
                        SportsRecordRow(record: record, pending: store.isPending(record.id))
                    }
                    .buttonStyle(.plain).disabled(store.syncing)
                }
            }
        }
    }
}

private struct SportsRecordRow: View {
    let record: SportsRecord
    let pending: Bool
    var body: some View {
        HStack(spacing: 10) {
            SportsTypeIcon(type: record.type)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.type).font(.system(size: 13, weight: .semibold))
                Text(record.date + (pending ? " · 待同步" : " · 已同步"))
                    .font(.system(size: 11)).foregroundStyle(SportsStyle.muted)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.2f", record.distance)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("km").font(.system(size: 11)).foregroundStyle(SportsStyle.muted)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(SportsStyle.muted)
                }
                Text("\(record.duration) 分钟").font(.system(size: 11)).foregroundStyle(SportsStyle.muted)
            }
        }
        .padding(.vertical, 14).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SportsTypeIcon: View {
    let type: String
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: SportsStyle.symbol(type)).font(.system(size: size * 0.45))
            .foregroundStyle(SportsStyle.color(type)).frame(width: size, height: size)
            .background(SportsStyle.color(type).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
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
        ScrollView {
            VStack(spacing: 14) {
                if let record {
                    VStack(spacing: 20) {
                        VStack(spacing: 12) {
                            SportsTypeIcon(type: record.type, size: 48)
                            Text(record.type).font(.system(size: 28, weight: .bold))
                            Text(record.date).font(.caption).foregroundStyle(SportsStyle.muted)
                        }.padding(.top, 8)
                        HStack(spacing: 0) {
                            SportsMetricValue(title: "运动距离", value: String(format: "%.2f", record.distance), unit: "km")
                            Rectangle().fill(SportsStyle.line).frame(width: 1, height: 40)
                            SportsMetricValue(title: "运动时长", value: String(record.duration), unit: "分钟")
                        }.padding(.vertical, 12)
                        Rectangle().fill(SportsStyle.line).frame(height: 1)
                        HStack {
                            Text("同步状态").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(store.isPending(id) ? "待同步" : "已同步").font(.system(size: 13)).foregroundStyle(SportsStyle.muted)
                        }
                    }.sportsPanel(padding: 20)
                    Button("删除运动记录", role: .destructive) { deleting = true }
                        .foregroundStyle(.red)
                        .font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 48)
                        .background(SportsStyle.card, in: RoundedRectangle(cornerRadius: 10))
                        .disabled(store.syncing)
                    Text("编辑和删除先保存在本地，下次进入时自动同步。")
                        .font(.system(size: 11)).foregroundStyle(SportsStyle.muted).multilineTextAlignment(.center)
                } else { ContentUnavailableView("记录已不存在", systemImage: "figure.run") }
            }.padding(20)
        }
        .background(SportsStyle.background).foregroundStyle(SportsStyle.text)
        .navigationTitle("运动详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("编辑") { editing = true }.disabled(record == nil || store.syncing) }
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
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("日期").font(.system(size: 12)).foregroundStyle(SportsStyle.muted)
                            DatePicker("日期", selection: $date, in: ...Self.today.addingTimeInterval(86_399), displayedComponents: .date)
                                .labelsHidden().datePickerStyle(.compact).accessibilityLabel("日期")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(SportsStyle.background, in: RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("运动类型").font(.system(size: 12)).foregroundStyle(SportsStyle.muted)
                            Menu {
                                Picker("运动类型", selection: $type) {
                                    ForEach(SportsStyle.orderedTypes + Set([type]).subtracting(SportsStyle.orderedTypes).sorted(), id: \.self) { Text($0).tag($0) }
                                }
                            } label: {
                                HStack {
                                    Text(type)
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.caption)
                                }.font(.system(size: 16)).padding(12)
                                    .background(SportsStyle.background, in: RoundedRectangle(cornerRadius: 10))
                            }.accessibilityLabel("运动类型，\(type)")
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 14) { fields }
                            VStack(spacing: 18) { fields }
                        }
                        Text("无距离的运动填 0；同一天可以记录多次运动。")
                            .font(.system(size: 11)).foregroundStyle(SportsStyle.muted)
                        Button(action: save) {
                            Text(record == nil ? "保存记录" : "保存修改")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SportsStyle.card).frame(maxWidth: .infinity, minHeight: 48)
                                .background(SportsStyle.text, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(store.syncing)
                    }.sportsPanel(padding: 18)
                    Text("先保存在本地，下次进入时自动同步。")
                        .font(.system(size: 11)).foregroundStyle(SportsStyle.muted)
                }.padding(20)
            }
            .background(SportsStyle.background).foregroundStyle(SportsStyle.text)
            // Date-only records must not move to a neighboring day in a different local zone.
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .navigationTitle(record == nil ? "记录一次运动" : "编辑运动记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .alert("无法保存记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    @ViewBuilder private var fields: some View {
        field("运动距离 · km", value: $distance, placeholder: "例如 1.05", keyboard: .decimalPad)
        field("运动时长 · 分钟", value: $duration, placeholder: "例如 69", keyboard: .numberPad)
    }

    private func field(_ name: String, value: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(name).font(.system(size: 12)).foregroundStyle(SportsStyle.muted)
            TextField(placeholder, text: value).font(.system(size: 16))
                .keyboardType(keyboard).accessibilityLabel(name)
                .padding(12).background(SportsStyle.background, in: RoundedRectangle(cornerRadius: 10))
        }.frame(maxWidth: .infinity, alignment: .leading)
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
