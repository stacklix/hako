import SwiftUI
import Charts

struct DeviceResourceHistoryView: View {
    let agent: ConsoleAgent
    let liveRefresh: Bool
    let refreshID: UUID
    let liveSample: DeviceResourceHistorySample?
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var range: DeviceResourceHistoryRange = .recent
    @State private var showsRanges = false
    @State private var series = DeviceResourceHistoryLiveSeries()
    @State private var error: String?
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var selectedDate: Date?
    private var connectionState: DeviceMonitorInventory.ConnectionState { client.connectionState(for: agent.id) }

    private var taskID: String {
        "\(client.requestContext)-\(client.authenticated)-\(connectionState.rawValue)-\(range.rawValue)-\(scenePhase)-\(refreshID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("历史利用率").font(.subheadline.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                rangeSelector
            }.zIndex(40)
            if let history = series.history {
                if history.points.isEmpty {
                    Text("此时间范围暂无历史记录。Kage 运行后每秒采样一次。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    resourceChart(history, cpu: true)
                    resourceChart(history, cpu: false)
                    Text(range == .recent ? "每个点对应一次采样，约每秒一次，不做聚合。"
                         : "每个点代表 \(history.bucketDurationText)内采样的平均值，末段按实际时长统计。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("共 \(history.sampleCount) 次采样 · 按住曲线查看\(range == .recent ? "采样时间" : "该点的起止时间")和数值。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let samplingError = history.samplingError {
                    Label(samplingError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if let last = history.lastSampleAt {
                    Text("最近采样：\(DeviceResourceHistory.date(last).formatted(date: .numeric, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if !loading && error == nil {
                Text("等待历史数据").font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            Text(liveRefresh ? "实时刷新已开启 · 随实时采样更新曲线" : "开启「实时刷新」后自动更新历史曲线")
                .font(.caption2).foregroundStyle(.secondary)
            Text("与实时指标共用每秒采样，每 5 分钟批量写盘，保留最近 7 天；未写盘数据也可查看。Kage 正常退出时保存，异常退出可能丢失最近 5 分钟的数据。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .devicePagePanel()
        .onDisappear { showsRanges = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { showsRanges = false } }
        .onChange(of: liveSample, initial: true) { _, _ in appendLiveSample() }
        .onChange(of: liveRefresh) { _, enabled in if enabled { appendLiveSample() } }
        .task(id: taskID) {
            guard scenePhase == .active, client.authenticated else { return }
            guard connectionState != .unknown else { error = nil; return }
            guard connectionState == .online else { error = "设备离线，暂时无法读取本机历史。"; return }
            error = nil
            if series.range != range {
                series = DeviceResourceHistoryLiveSeries(range: range)
                selectedDate = nil
            }
            await load()
        }
    }

    private var rangeSelector: some View {
        let accent = HakoStyle.adaptive(0x514298, 0xc5b7ff)
        let selectedFill = HakoStyle.adaptive(0xf0eef8, 0x2b2936)
        return Button { showsRanges.toggle() } label: {
            HStack(spacing: 5) { Text(range.title); Image(systemName: "chevron.down").font(.caption2) }
                .font(.caption.weight(.medium)).foregroundStyle(accent).frame(minHeight: 38)
        }
        .buttonStyle(.plain).accessibilityLabel("历史时间范围")
        .accessibilityValue(range.title + (showsRanges ? "，已展开" : "，已收起"))
        .overlay(alignment: .topTrailing) {
            if showsRanges {
                VStack(spacing: 2) {
                    ForEach(DeviceResourceHistoryRange.allCases) { option in
                        Button { range = option; selectedDate = nil; showsRanges = false } label: {
                            HStack(spacing: 12) {
                                Text(option.title); Spacer(minLength: 4)
                                if range == option { Image(systemName: "checkmark").font(.caption) }
                            }
                            .font(.subheadline).foregroundStyle(range == option ? accent : Color.primary)
                            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(range == option ? selectedFill : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(range == option ? .isSelected : [])
                    }
                }
                .padding(5).frame(width: 174)
                .background(HakoStyle.adaptive(0xffffff, 0x323237), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6).offset(y: 43)
                .accessibilityElement(children: .contain).accessibilityLabel("历史时间范围选项")
                .accessibilityAction(.escape) { showsRanges = false }.zIndex(20)
            }
        }.zIndex(showsRanges ? 20 : 0)
    }

    private func load() async {
        let requestedRange = range
        let requestID = UUID()
        loadID = requestID
        loading = true
        defer { if loadID == requestID { loading = false } }
        do {
            let result = try await client.invokeAgent(agent, method: DeviceResourceHistoryCommand.name, version: 1,
                params: requestedRange.parameters, as: DeviceResourceHistory.self)
            try Task.checkCancellation()
            guard requestedRange == range, series.range == requestedRange else { return }
            guard requestedRange.accepts(result) else {
                throw HakoError(message: "设备返回的历史数据格式无效。")
            }
            series.seed(result)
            error = nil
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func appendLiveSample() {
        guard liveRefresh, scenePhase == .active, agent.online, client.authenticated, let liveSample else { return }
        if series.range != range { series = DeviceResourceHistoryLiveSeries(range: range) }
        series.append(liveSample)
    }

    private func resourceChart(_ history: DeviceResourceHistory, cpu: Bool) -> some View {
        let color: Color = cpu ? .blue : .purple
        let selected = selectedDate.flatMap { history.displayPoint(at: $0, for: range) }
        let average = cpu ? history.cpuAverage : history.memoryAverage
        return VStack(alignment: .leading, spacing: 8) {
            Text(cpu ? "CPU" : "内存").font(.subheadline.weight(.medium))
            Text(String(format: "平均 %.1f%%", average))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Chart {
                ForEach(history.displayPoints(for: range)) { point in
                    LineMark(x: .value("时间", point.date), y: .value("使用率", cpu ? point.source.cpuUsagePercent : point.source.memoryUsagePercent))
                        .foregroundStyle(color)
                    if history.points.count == 1 && !point.carried {
                        PointMark(x: .value("时间", point.date), y: .value("使用率", cpu ? point.source.cpuUsagePercent : point.source.memoryUsagePercent))
                            .foregroundStyle(color)
                    }
                }
                if let selected {
                    RuleMark(x: .value("选中时间", selected.date)).foregroundStyle(.secondary.opacity(0.4))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: DeviceResourceHistory.date(history.from < history.to ? history.from : history.from - 1000)...DeviceResourceHistory.date(history.to))
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
            } }
            .chartXSelection(value: $selectedDate)
            .frame(height: 150)
            .accessibilityLabel(cpu ? "CPU 历史使用率" : "内存历史使用率")
            if let selected {
                Text((range == .recent ? selected.date.formatted(date: .numeric, time: .standard)
                      : intervalLabel(DateInterval(start: selected.date,
                          end: DeviceResourceHistory.date(min(history.to, selected.timestamp + Int64(history.bucketSeconds) * 1000)))))
                     + String(format: range == .recent ? " · 使用率 %.1f%%" : " · 分段平均 %.1f%%", cpu ? selected.source.cpuUsagePercent : selected.source.memoryUsagePercent))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                if range != .recent && !selected.carried {
                    Text("该时段共 \(selected.source.sampleCount) 次有效采样")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func intervalLabel(_ interval: DateInterval) -> String {
        let includesDate = [.day, .week].contains(range)
            || !Calendar.current.isDate(interval.start, inSameDayAs: interval.end)
        let dateStyle: Date.FormatStyle.DateStyle = includesDate ? .numeric : .omitted
        let start = interval.start.formatted(date: dateStyle, time: .standard)
        if interval.duration == 0 { return start + "（当前采样）" }
        return start + " – " + interval.end.formatted(date: dateStyle, time: .standard)
    }

}
