import SwiftUI
import Charts

struct InvestmentAPIUsageChart: View {
    let source: InvestmentQuoteSource
    @State private var snapshot: MarketAPIUsageSnapshot?
    @State private var selectedHour: Double?
    @State private var error: String?
    @State private var showsFailures = true
    @State private var expandedFailureID: UUID?

    private var provider: MarketAPIProvider { source == .tushare ? .tushare : .twelveData }
    private var hours: [MarketAPIHourUsage] { snapshot?.hours ?? [] }
    private var step: Int { max(1, Int(ceil(Double(hours.map { max($0.succeeded, $0.failed) }.max() ?? 0) / 3))) }
    private var selection: MarketAPIHourUsage? {
        guard let selectedHour else { return nil }
        let index = Int(selectedHour.rounded())
        return hours.indices.contains(index) ? hours[index] : nil
    }

    var body: some View {
        Group {
            Section {
                statistics.investmentListRow()
            } header: {
                Text("调用统计")
            } footer: {
                Text("最近24个小时（含当前小时），按本机已完成的请求分别统计成功与失败，包含搜索、行情、汇率和连接测试；缓存命中不计入。网络、HTTP 和接口业务错误计为失败。")
                if source == .twelveData { Text("Twelve Data 包含 Binance Stock 报价。") }
            }
            if let snapshot, snapshot.failed > 0 {
                Section {
                    failureDetails(snapshot).investmentListRow()
                } footer: {
                    Text("HTTP 200 也可能包含接口业务错误。每个行情源独立保存最近24小时内最多200条失败详情。")
                }
            }
        }
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近24小时").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let snapshot { Text("共 \(snapshot.total) 次").font(.subheadline.weight(.medium)).monospacedDigit() }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if snapshot != nil {
                if let snapshot {
                    HStack(spacing: 18) {
                        legend("成功", count: snapshot.succeeded, color: .green)
                        legend("失败", count: snapshot.failed, color: .red)
                    }
                }
                chart
                if let selection {
                    Text(selection.hour.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted))) + "时 · 成功 \(selection.succeeded) · 失败 \(selection.failed)")
                        .font(.caption).monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .padding(.horizontal, 6)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(snapshot?.total == 0 ? "暂无调用记录" : "点击柱形查看该小时次数")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if snapshot?.persistenceFailed == true {
                    Text("调用记录暂未写入本机存储。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            snapshot = nil; expandedFailureID = nil; showsFailures = true
            while !Task.isCancelled {
                do {
                    let updated = try await MarketAPIUsage.shared.snapshot(for: provider)
                    if snapshot?.hours.first?.hour != updated.hours.first?.hour { selectedHour = 23 }
                    if snapshot == nil { expandedFailureID = updated.failures.first?.id }
                    else if let expandedFailureID, !updated.failures.contains(where: { $0.id == expandedFailureID }) {
                        self.expandedFailureID = nil
                    }
                    snapshot = updated; error = nil
                } catch { self.error = "暂时无法读取本机调用记录。" }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func failureDetails(_ snapshot: MarketAPIUsageSnapshot) -> some View {
        DisclosureGroup(isExpanded: $showsFailures) {
            if snapshot.failures.isEmpty {
                Text("此前只记录了失败次数。更新后的新请求会保存具体原因。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.failures) { failure in
                        failureRow(failure)
                        if failure.id != snapshot.failures.last?.id { Divider() }
                    }
                    Text("按时间倒序显示，API Key、Token 等凭据已隐藏；更新前的记录无法补回错误详情。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        } label: {
            Text("失败详情（\(snapshot.failures.count)条）").font(.subheadline)
        }
        .padding(.vertical, 8)
    }

    private func failureRow(_ failure: MarketAPIFailure) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedFailureID == failure.id },
            set: { expanded in
                if expanded { expandedFailureID = failure.id }
                else if expandedFailureID == failure.id { expandedFailureID = nil }
            })) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("请求时间", value: failure.time.formatted(.dateTime.year().month().day().hour().minute().second()))
                LabeledContent("接口", value: failure.endpoint)
                LabeledContent("HTTP 状态", value: failure.httpStatus.map(String.init) ?? "未收到响应")
                if let code = failure.code { LabeledContent("错误码", value: code) }
                Text("错误信息").foregroundStyle(.secondary)
                Text(failure.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": failure.diagnosticText]],
                                                  options: [.localOnly: true])
                } label: {
                    Label("复制错误信息", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("复制这条失败记录的脱敏错误信息")
            }
            .font(.caption)
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Label(failure.title, systemImage: "exclamationmark.circle")
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(failure.time, format: .dateTime.hour().minute().second())
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(failure.endpoint + " · " + (failure.httpStatus.map { "HTTP \($0)" } ?? "未收到响应")
                    + (failure.code.map { " · 错误码 " + $0 } ?? ""))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func legend(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(title) \(count) 次").font(.caption).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                BarMark(x: .value("小时", Double(index)), y: .value("次数", hour.succeeded), width: .ratio(0.75))
                    .position(by: .value("结果", "成功"))
                    .foregroundStyle(Color.green.opacity(selection == nil || selection?.hour == hour.hour ? 0.9 : 0.65))
                    .cornerRadius(2)
                    .accessibilityLabel(hour.hour.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted))) + "时成功")
                    .accessibilityValue("\(hour.succeeded)次")
                BarMark(x: .value("小时", Double(index)), y: .value("次数", hour.failed), width: .ratio(0.75))
                    .position(by: .value("结果", "失败"))
                    .foregroundStyle(Color.red.opacity(selection == nil || selection?.hour == hour.hour ? 0.9 : 0.65))
                    .cornerRadius(2)
                    .accessibilityLabel(hour.hour.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted))) + "时失败")
                    .accessibilityValue("\(hour.failed)次")
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: 0...(step * 3))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: [0.0, 6, 12, 18, 23]) { axis in
                if let value = axis.as(Double.self), hours.indices.contains(Int(value)) {
                    AxisValueLabel {
                        Text(hours[Int(value)].hour, format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                            .font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, step, step * 2, step * 3]) { axis in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let count = axis.as(Int.self) { Text(count.formatted()).font(.caption2).monospacedDigit() }
                }
            }
        }
        .chartXAxisLabel("小时", alignment: .trailing)
        .chartYAxisLabel("次数")
        .chartXSelection(value: $selectedHour)
        .frame(height: 180)
        .accessibilityLabel(source.title + "最近24小时成功与失败调用次数")
    }
}
